import Foundation
import CoreAudio
import AudioToolbox
import Combine

/// Turns raw audio into a handful of frequency bands, low notes first.
/// Runs entirely on the audio thread's serial queue.
final class SpectrumAnalyzer {
    let bandCount: Int
    private let frameSize = 2048            // ~43 ms at 48 kHz: good bass resolution, ~23 updates/s
    private let log2n = 11
    private var buffer: [Float] = []
    private let window: [Float]
    /// FFT bin range [start, end) for each band.
    private let ranges: [Range<Int>]
    private let fft: FFT
    private let hop = 1024                  // overlap windows: ~47 updates/s
    private var peak: Float = 1e-3
    private var smoothed: [Float]
    private var bandPeak: [Float]
    private var bandFloor: [Float]

    /// Levels 0…1 per band, and whether there's any real signal.
    var onLevels: (([Float], Bool) -> Void)?

    init(bands: Int, sampleRate: Double) {
        bandCount = bands
        smoothed = [Float](repeating: 0, count: bands)
        bandPeak = [Float](repeating: 1e-3, count: bands)
        bandFloor = [Float](repeating: 0, count: bands)
        buffer.reserveCapacity(frameSize * 2)
        fft = FFT(size: frameSize)

        var w = [Float](repeating: 0, count: frameSize)
        for i in 0..<frameSize {
            w[i] = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(frameSize - 1)))
        }
        window = w

        // Log-spaced bands from 40 Hz to 12 kHz.
        let low = 40.0, high = 12_000.0
        let binHz = sampleRate / Double(frameSize)
        let maxBin = frameSize / 2
        var r: [Range<Int>] = []
        for b in 0..<bands {
            let lo = low * pow(high / low, Double(b) / Double(bands))
            let hi = low * pow(high / low, Double(b + 1) / Double(bands))
            let start = min(maxBin - 1, max(1, Int((lo / binHz).rounded(.down))))
            let end = min(maxBin, max(start + 1, Int((hi / binHz).rounded(.up))))
            r.append(start..<end)
        }
        ranges = r
    }

    /// Feeds interleaved Float32 samples.
    func push(_ samples: UnsafePointer<Float>, count: Int, channels: Int) {
        let ch = max(1, channels)
        let frames = count / ch
        guard frames > 0 else { return }
        for i in 0..<frames {
            var v: Float = 0
            for c in 0..<ch { v += samples[i * ch + c] }
            buffer.append(v / Float(ch))
        }
        while buffer.count >= frameSize {
            analyze(start: buffer.count - frameSize)
            // Keep the newest part so the next window overlaps this one.
            buffer.removeFirst(buffer.count - (frameSize - hop))
        }
    }

    private func analyze(start: Int) {
        var re = [Float](repeating: 0, count: frameSize)
        var im = [Float](repeating: 0, count: frameSize)
        for i in 0..<frameSize { re[i] = buffer[start + i] * window[i] }
        fft.forward(&re, &im)

        var amps = [Float](repeating: 0, count: bandCount)
        var loudest: Float = 0
        for b in 0..<bandCount {
            var sum: Float = 0
            for k in ranges[b] { sum += re[k] * re[k] + im[k] * im[k] }
            // Average power per bin, then a gentle tilt: music has much more energy in the bass.
            let tilt: Float = 1 + Float(b) * 0.35
            let amp = sqrt(sum / Float(ranges[b].count)) * tilt
            amps[b] = amp
            loudest = max(loudest, amp)
        }

        // Automatic gain, globally and per band, so every bar uses its full height.
        peak = max(loudest, peak * 0.995, 1e-3)
        let hasSignal = loudest > 0.05
        for b in 0..<bandCount {
            let a = amps[b]
            // Each band follows its own recent loud point and its own "resting" level,
            // so beats and hits stand out instead of every bar hovering near the top.
            bandPeak[b] = max(a, bandPeak[b] * 0.985, peak * 0.05)
            bandFloor[b] = a < bandFloor[b] ? a : bandFloor[b] + (a - bandFloor[b]) * 0.02
            let span = max(bandPeak[b] - bandFloor[b], peak * 0.05)
            let local = min(1, max(0, (a - bandFloor[b]) / span))
            let global = min(1, a / peak)
            let mixed = 0.8 * local + 0.2 * global
            let target = hasSignal ? pow(mixed, 1.15) : 0
            let s = smoothed[b]
            // Jump up fast, fall back quickly too, so the motion is easy to see.
            smoothed[b] = target > s ? s + (target - s) * 0.85 : s + (target - s) * 0.45
        }
        onLevels?(smoothed, hasSignal)
    }
}

/// Small in-place radix-2 FFT (no framework dependency, so it behaves the same everywhere).
final class FFT {
    let size: Int
    private let cosTable: [Float]
    private let sinTable: [Float]
    private let bitReverse: [Int]

    init(size: Int) {
        self.size = size
        var c = [Float](repeating: 0, count: size / 2)
        var s = [Float](repeating: 0, count: size / 2)
        for i in 0..<size / 2 {
            let a = -2 * Double.pi * Double(i) / Double(size)
            c[i] = Float(cos(a))
            s[i] = Float(sin(a))
        }
        cosTable = c
        sinTable = s
        var bits = 0
        while (1 << bits) < size { bits += 1 }
        var rev = [Int](repeating: 0, count: size)
        for i in 0..<size {
            var x = i, r = 0
            for _ in 0..<bits { r = (r << 1) | (x & 1); x >>= 1 }
            rev[i] = r
        }
        bitReverse = rev
    }

    func forward(_ re: inout [Float], _ im: inout [Float]) {
        let n = size
        for i in 0..<n {
            let j = bitReverse[i]
            if j > i {
                re.swapAt(i, j)
                im.swapAt(i, j)
            }
        }
        var len = 2
        while len <= n {
            let half = len / 2
            let step = n / len
            var i = 0
            while i < n {
                for k in 0..<half {
                    let wr = cosTable[k * step], wi = sinTable[k * step]
                    let a = i + k, b = a + half
                    let tr = re[b] * wr - im[b] * wi
                    let ti = re[b] * wi + im[b] * wr
                    re[b] = re[a] - tr
                    im[b] = im[a] - ti
                    re[a] += tr
                    im[a] += ti
                }
                i += len
            }
            len <<= 1
        }
    }
}

/// Listens to what Music or Spotify is playing (not the rest of the Mac) and keeps
/// `levels` up to date, only while a visualizer is on screen.
@available(macOS 14.2, *)
private final class SpectrumTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "driftdock.spectrum.io", qos: .userInteractive)
    private var analyzer: SpectrumAnalyzer?

    /// Returns false if macOS refused (usually: System Audio Recording not allowed yet).
    func start(processes: [AudioObjectID], bands: Int, onLevels: @escaping ([Float], Bool) -> Void) -> Bool {
        let description: CATapDescription
        if processes.isEmpty {
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        } else {
            description = CATapDescription(stereoMixdownOfProcesses: processes)
        }
        description.uuid = UUID()
        description.name = "Driftdock Visualizer"
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior.unmuted   // listen only; the music plays as normal

        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr else { return false }
        tapID = tap

        guard let output = AudioProcesses.defaultOutputDevice(), let outputUID = AudioProcesses.uid(of: output) else {
            stop()
            return false
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Driftdock Visualizer",
            kAudioAggregateDeviceUIDKey: "driftdock.visualizer.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg) == noErr else {
            stop()
            return false
        }
        aggregateID = agg

        var rate: Float64 = 48_000
        var rateAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        _ = AudioObjectGetPropertyData(agg, &rateAddr, 0, nil, &rateSize, &rate)

        let analyzer = SpectrumAnalyzer(bands: bands, sampleRate: rate > 0 ? rate : 48_000)
        analyzer.onLevels = onLevels
        self.analyzer = analyzer

        var proc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, queue) { _, inInput, _, outOutput, _ in
            let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
            let outputs = UnsafeMutableAudioBufferListPointer(outOutput)
            // We only listen: send silence to the speakers from this device.
            for i in 0..<outputs.count {
                let outBuf = outputs[i]
                guard let outData = outBuf.mData else { continue }
                memset(outData, 0, Int(outBuf.mDataByteSize))
            }
            // The tap is the last input stream on the aggregate device.
            guard inputs.count > 0 else { return }
            let source = inputs[inputs.count - 1]
            guard let inData = source.mData else { return }
            let count = Int(source.mDataByteSize) / MemoryLayout<Float>.size
            analyzer.push(inData.assumingMemoryBound(to: Float.self), count: count,
                          channels: Int(source.mNumberChannels))
        }
        guard procStatus == noErr, let proc else { stop(); return false }
        procID = proc
        guard AudioDeviceStart(agg, proc) == noErr else { stop(); return false }
        return true
    }

    func stop() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        analyzer?.onLevels = nil
        analyzer = nil
    }
}

final class SpectrumModel: ObservableObject {
    static let shared = SpectrumModel()

    /// Band levels 0…1, bass first.
    @Published private(set) var levels: [Float] = []
    /// True while real audio is coming in. When false, visualizers fall back to a gentle animation.
    @Published private(set) var isLive = false

    static let bands = 10
    private var users = 0
    private var session: AnyObject?
    private var lastSignal = Date.distantPast
    private var refusedAt = Date.distantPast
    private var cancellables = Set<AnyCancellable>()
    private var outputListener: AudioObjectPropertyListenerBlock?

    private init() {
        // A different player (Music ↔ Spotify) means a different process to listen to.
        NowPlayingModel.shared.$player
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.restart() } }
            .store(in: &cancellables)
        AppState.shared.$config
            .map(\.reactiveVisualizer)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.update() } }
            .store(in: &cancellables)

        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.restart() }
        outputListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
    }

    /// Visualizers call these as they appear and disappear.
    func retain() { users += 1; update() }
    func release() { users = max(0, users - 1); update() }

    private func update() {
        let want = users > 0 && AppState.shared.config.reactiveVisualizer
            && Date().timeIntervalSince(refusedAt) > 60     // don't hammer macOS after a refusal
        if want && session == nil { start() }
        if !want && session != nil { stop() }
    }

    private func restart() {
        guard session != nil else { return }
        stop()
        update()
    }

    private func start() {
        guard #available(macOS 14.2, *) else { return }
        let tap = SpectrumTap()
        let ok = tap.start(processes: playerProcesses(), bands: Self.bands) { [weak self] levels, signal in
            DispatchQueue.main.async {
                guard let self, self.session != nil else { return }
                self.levels = levels
                if signal { self.lastSignal = Date() }
                // Live if there was sound in the last 2.5 s (taps deliver silence until allowed).
                let live = Date().timeIntervalSince(self.lastSignal) < 2.5
                if live != self.isLive { self.isLive = live }
            }
        }
        if ok {
            session = tap
        } else {
            refusedAt = Date()
            isLive = false
        }
    }

    private func stop() {
        if #available(macOS 14.2, *) { (session as? SpectrumTap)?.stop() }
        session = nil
        if isLive { isLive = false }
        levels = []
    }

    /// The audio processes for the app that's playing, so notification sounds don't move the bars.
    private func playerProcesses() -> [AudioObjectID] {
        guard #available(macOS 14.2, *) else { return [] }
        let id: String
        switch NowPlayingModel.shared.player {
        case "Spotify": id = "com.spotify.client"
        case "Music": id = "com.apple.Music"
        default: return []
        }
        return AudioProcesses.apps().first { $0.bundleID == id }?.processObjects ?? []
    }
}
