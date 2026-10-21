import Foundation
import AppKit
import CoreAudio
import AudioToolbox
import Combine

// MARK: - EQ

enum Equalizer {
    static let frequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let labels = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    static let maxGain = 12.0

    static let presets: [(name: String, gains: [Double])] = [
        ("Flat", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        ("Bass Boost", [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        ("Bass Reducer", [-6, -5, -4, -2, 0, 0, 0, 0, 0, 0]),
        ("Treble Boost", [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]),
        ("Vocal", [-2, -2, -1, 1, 3, 4, 3, 1, 0, -1]),
        ("Podcast", [-4, -2, 0, 2, 4, 4, 3, 1, 0, -2]),
        ("Rock", [4, 3, 2, 0, -1, -1, 1, 3, 4, 4]),
        ("Electronic", [5, 4, 1, 0, -2, 1, 0, 2, 4, 5]),
        ("Hip-Hop", [5, 4, 2, 3, -1, -1, 1, 0, 2, 3]),
        ("Acoustic", [3, 3, 2, 1, 1, 1, 2, 3, 2, 1]),
        ("Loudness", [6, 4, 0, 0, -2, 0, -1, -3, 4, 2]),
        ("Late Night", [-3, -2, 0, 2, 3, 3, 2, 0, -2, -3]),
    ]

    /// RBJ peaking filter, normalized: [b0, b1, b2, a1, a2].
    static func peaking(freq: Double, gainDB: Double, sampleRate: Double, q: Double = 1.41) -> [Float] {
        let f = min(freq, sampleRate * 0.45)
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * f / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let b0 = 1 + alpha * a, b1 = -2 * cosw, b2 = 1 - alpha * a
        let a0 = 1 + alpha / a, a1 = -2 * cosw, a2 = 1 - alpha / a
        return [Float(b0 / a0), Float(b1 / a0), Float(b2 / a0), Float(a1 / a0), Float(a2 / a0)]
    }
}

/// Everything the audio thread needs, swapped in whole when a setting changes.
final class DSPConfig {
    let tapGains: [Float]          // one per tap, in tap order
    let eqOn: Bool
    let coeffs: [[Float]]          // per band
    let preamp: Float
    let leftGain: Float
    let rightGain: Float

    init(tapGains: [Float], eqOn: Bool, coeffs: [[Float]], preamp: Float, leftGain: Float, rightGain: Float) {
        self.tapGains = tapGains
        self.eqOn = eqOn
        self.coeffs = coeffs
        self.preamp = preamp
        self.leftGain = leftGain
        self.rightGain = rightGain
    }
}

// MARK: - Engine

/// One aggregate device holding a system-wide tap (all apps except Driftdock and the
/// apps with their own volume) plus a tap per custom-volume app. One callback mixes
/// them with their gains, runs the EQ, balance and boost, and plays the result.
@available(macOS 14.2, *)
final class MixerEngine {
    enum EngineError: LocalizedError {
        case permission, noOutput, ownProcess, route(OSStatus)
        var errorDescription: String? {
            switch self {
            case .permission: return "Allow Driftdock under Privacy & Security → Screen & System Audio Recording"
            case .noOutput: return "No audio output device"
            case .ownProcess: return "Couldn't start the mixer yet. Try again in a moment"
            case .route(let s): return "Couldn't route audio (\(s))"
            }
        }
    }

    /// Which taps this engine was built with (to know when a rebuild is needed).
    let customApps: [String]
    let processSignature: [AudioObjectID]

    private var taps: [AudioObjectID] = []
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "driftdock.mixer.engine", qos: .userInteractive)
    private let lock = NSLock()
    private var config: DSPConfig
    private(set) var sampleRate: Double = 48_000

    // Audio-thread state (touched only inside the callback).
    private var state: [Float] = Array(repeating: 0, count: 10 * 2 * 2)   // band × channel × (z1, z2)
    private var mixL: [Float] = []
    private var mixR: [Float] = []

    init(customApps: [String], processSignature: [AudioObjectID], config: DSPConfig) {
        self.customApps = customApps
        self.processSignature = processSignature
        self.config = config
    }

    func update(_ c: DSPConfig) {
        lock.lock()
        config = c
        lock.unlock()
    }

    /// `appProcesses` lists each custom app's processes, in the same order as `customApps`.
    func start(appProcesses: [[AudioObjectID]]) throws {
        guard let me = AudioProcesses.ownProcessObject() else { throw EngineError.ownProcess }
        let excluded = [me] + appProcesses.flatMap { $0 }

        var tapUUIDs: [String] = []
        func makeTap(_ d: CATapDescription) throws {
            d.uuid = UUID()
            d.isPrivate = true
            d.muteBehavior = CATapMuteBehavior.mutedWhenTapped
            var tap = AudioObjectID(kAudioObjectUnknown)
            guard AudioHardwareCreateProcessTap(d, &tap) == noErr else { throw EngineError.permission }
            taps.append(tap)
            tapUUIDs.append(d.uuid.uuidString)
        }

        do {
            let global = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
            global.name = "Driftdock Mixer (everything else)"
            try makeTap(global)
            for (i, procs) in appProcesses.enumerated() {
                let d = CATapDescription(stereoMixdownOfProcesses: procs)
                d.name = "Driftdock Mixer (\(customApps[i]))"
                try makeTap(d)
            }
        } catch {
            stop()
            throw error
        }

        guard let output = AudioProcesses.defaultOutputDevice(), let outputUID = AudioProcesses.uid(of: output) else {
            stop()
            throw EngineError.noOutput
        }
        let tapList: [[String: Any]] = tapUUIDs.map { [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: $0] }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Driftdock Mixer",
            kAudioAggregateDeviceUIDKey: "driftdock.engine.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: tapList,
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg)
        guard aggStatus == noErr else { stop(); throw EngineError.route(aggStatus) }
        aggregateID = agg

        var rate: Float64 = 48_000
        var rateAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        if AudioObjectGetPropertyData(agg, &rateAddr, 0, nil, &rateSize, &rate) == noErr, rate > 0 { sampleRate = rate }

        let tapCount = taps.count
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, queue) { [weak self] _, inInput, _, outOutput, _ in
            self?.render(inInput, outOutput, tapCount: tapCount)
        }
        guard status == noErr, let proc else { stop(); throw EngineError.route(status) }
        procID = proc
        let startStatus = AudioDeviceStart(agg, proc)
        guard startStatus == noErr else { stop(); throw EngineError.route(startStatus) }
    }

    func stop() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        for t in taps { AudioHardwareDestroyProcessTap(t) }
        taps.removeAll()
    }

    // MARK: Audio thread

    private func render(_ inInput: UnsafePointer<AudioBufferList>, _ outOutput: UnsafeMutablePointer<AudioBufferList>, tapCount: Int) {
        lock.lock()
        let c = config
        lock.unlock()

        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
        let outputs = UnsafeMutableAudioBufferListPointer(outOutput)
        guard outputs.count > 0, let outData = outputs[0].mData else { return }
        let outChannels = max(1, Int(outputs[0].mNumberChannels))
        let frames = Int(outputs[0].mDataByteSize) / MemoryLayout<Float>.size / outChannels
        let out = outData.assumingMemoryBound(to: Float.self)

        if mixL.count < frames {
            mixL = [Float](repeating: 0, count: frames)
            mixR = [Float](repeating: 0, count: frames)
        }
        for i in 0..<frames { mixL[i] = 0; mixR[i] = 0 }

        // Mix the taps (they're the last `tapCount` input streams, in tap order).
        let firstTap = max(0, inputs.count - tapCount)
        for t in 0..<min(tapCount, inputs.count) {
            let buf = inputs[firstTap + t]
            guard let data = buf.mData else { continue }
            let ch = max(1, Int(buf.mNumberChannels))
            let n = min(frames, Int(buf.mDataByteSize) / MemoryLayout<Float>.size / ch)
            let src = data.assumingMemoryBound(to: Float.self)
            let g = t < c.tapGains.count ? c.tapGains[t] : 1
            if g == 0 { continue }
            for i in 0..<n {
                let l = src[i * ch]
                let r = ch > 1 ? src[i * ch + 1] : l
                mixL[i] += l * g
                mixR[i] += r * g
            }
        }

        // EQ: a cascade of peaking filters per channel (transposed direct form II).
        if c.eqOn {
            for b in 0..<min(10, c.coeffs.count) {
                let k = c.coeffs[b]
                let b0 = k[0], b1 = k[1], b2 = k[2], a1 = k[3], a2 = k[4]
                for ch in 0..<2 {
                    let s = (b * 2 + ch) * 2
                    var z1 = state[s], z2 = state[s + 1]
                    if ch == 0 {
                        for i in 0..<frames {
                            let x = mixL[i]
                            let y = b0 * x + z1
                            z1 = b1 * x - a1 * y + z2
                            z2 = b2 * x - a2 * y
                            mixL[i] = y
                        }
                    } else {
                        for i in 0..<frames {
                            let x = mixR[i]
                            let y = b0 * x + z1
                            z1 = b1 * x - a1 * y + z2
                            z2 = b2 * x - a2 * y
                            mixR[i] = y
                        }
                    }
                    // Guard against blow-ups (e.g. after a device hiccup).
                    if !z1.isFinite || !z2.isFinite { z1 = 0; z2 = 0 }
                    state[s] = z1
                    state[s + 1] = z2
                }
            }
        }

        // Preamp/boost, balance, and a soft limiter so boosts don't crackle.
        let gl = c.preamp * c.leftGain, gr = c.preamp * c.rightGain
        for i in 0..<frames {
            let l = Self.soft(mixL[i] * gl)
            let r = Self.soft(mixR[i] * gr)
            let o = i * outChannels
            if outChannels == 1 {
                out[o] = (l + r) * 0.5
            } else {
                out[o] = l
                out[o + 1] = r
                if outChannels > 2 { for extra in 2..<outChannels { out[o + extra] = 0 } }
            }
        }
        // Silence any other output streams.
        if outputs.count > 1 {
            for i in 1..<outputs.count {
                if let d = outputs[i].mData { memset(d, 0, Int(outputs[i].mDataByteSize)) }
            }
        }
    }

    @inline(__always)
    private static func soft(_ x: Float) -> Float {
        let a = abs(x)
        if a <= 0.8 { return x }
        let y = 0.8 + 0.2 * tanh((a - 0.8) / 0.2)
        return x < 0 ? -y : y
    }
}
