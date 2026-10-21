import SwiftUI
import AppKit
import Combine
import CoreAudio
import AudioToolbox

// MARK: - Audio processes

/// One app making (or able to make) sound, possibly made of several helper processes
/// (Safari's WebContent, Chrome's helpers…).
struct MixerApp: Identifiable, Equatable {
    let bundleID: String
    let name: String
    var processObjects: [AudioObjectID]
    var isPlaying: Bool
    var isRecording: Bool = false
    var id: String { bundleID }
}

enum AudioProcesses {
    private static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0) }
        return status == noErr ? value : nil
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(kAudioObjectUnknown))
    }

    static func uid(of device: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    /// Groups CoreAudio process objects by the app they belong to (macOS 14.2+).
    @available(macOS 14.2, *)
    static func apps() -> [MixerApp] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }

        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let me = Bundle.main.bundleIdentifier ?? ""
        var grouped: [String: MixerApp] = [:]

        for obj in ids {
            var bAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
            var bRef: Unmanaged<CFString>?
            var bSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(obj, &bAddr, 0, nil, &bSize, &bRef) == noErr,
                  let processBundle = bRef?.takeRetainedValue() as String?, !processBundle.isEmpty,
                  processBundle != me else { continue }

            // Map helper processes to their app: longest running-app bundle ID that prefixes it.
            var owner = running
                .filter { app in app.bundleIdentifier.map { processBundle.hasPrefix($0) } ?? false }
                .max { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }
            if owner == nil, processBundle.hasPrefix("com.apple.WebKit") {
                owner = running.first { $0.bundleIdentifier == "com.apple.Safari" }
            }
            guard let app = owner, let bundleID = app.bundleIdentifier else { continue }

            let playing = (get(obj, kAudioProcessPropertyIsRunningOutput, UInt32(0)) ?? 0) != 0
            let recording = (get(obj, kAudioProcessPropertyIsRunningInput, UInt32(0)) ?? 0) != 0
            if var existing = grouped[bundleID] {
                existing.processObjects.append(obj)
                existing.isPlaying = existing.isPlaying || playing
                existing.isRecording = existing.isRecording || recording
                grouped[bundleID] = existing
            } else {
                grouped[bundleID] = MixerApp(bundleID: bundleID, name: app.localizedName ?? bundleID,
                                             processObjects: [obj], isPlaying: playing, isRecording: recording)
            }
        }
        return grouped.values.sorted {
            $0.isPlaying != $1.isPlaying ? $0.isPlaying : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Driftdock's own audio process object, so a system-wide tap never records its own output.
    static func ownProcessObject() -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var pid = getpid()
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        return status == noErr && obj != kAudioObjectUnknown ? obj : nil
    }

    static func name(of device: AudioObjectID) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &name) == noErr, let name else { return "Output" }
        return name.takeRetainedValue() as String
    }

    /// Every device that can play sound.
    static func outputDevices() -> [OutputDevice] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        var out: [OutputDevice] = []
        for id in ids {
            var sAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput,
                                                   mElement: kAudioObjectPropertyElementMain)
            var sSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &sAddr, 0, nil, &sSize) == noErr, sSize > 0 else { continue }
            let transport = get(id, kAudioDevicePropertyTransportType, UInt32(0)) ?? 0
            let n = name(of: id)
            if n.hasPrefix("Driftdock") { continue }
            out.append(OutputDevice(id: id, name: n, transport: transport))
        }
        return out
    }

    static func setDefaultOutput(_ id: AudioObjectID) {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value = id
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                   UInt32(MemoryLayout<AudioObjectID>.size), &value)
    }
}

struct OutputDevice: Identifiable, Equatable {
    let id: AudioObjectID
    let name: String
    let transport: UInt32

    var symbol: String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return n.contains("headphone") ? "headphones" : "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeUSB: return "cable.connector"
        default: return "speaker.wave.2.fill"
        }
    }
}

// MARK: - Mixer model

/// Per-app volume, EQ, balance and boost. The engine only runs while something
/// differs from the defaults; otherwise audio isn't touched at all.
final class MixerModel: ObservableObject {
    static let shared = MixerModel()

    @Published private(set) var apps: [MixerApp] = []
    @Published private(set) var lastError: String?
    @Published private(set) var outputs: [OutputDevice] = []
    @Published private(set) var currentOutput: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    @Published private(set) var isProcessing = false

    private var engine: AnyObject?          // MixerEngine on macOS 14.2+
    private var timer: Timer?
    private var idleTicks = 0
    private var cancellables = Set<AnyCancellable>()
    private var listeners: [AudioObjectPropertyListenerBlock] = []
    private var retryAt = Date.distantPast
    /// How many mixer views are on screen.
    var visible = 0 {
        didSet { if visible > 0 && oldValue == 0 { refresh(); refreshOutputs() } }
    }

    static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    private init() {}

    func start() {
        guard Self.isSupported, timer == nil else { return }
        refresh()
        refreshOutputs()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.idleTicks += 1
            if self.visible > 0 || self.needsEngine || self.idleTicks % 8 == 0 { self.refresh() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // Settings that only change gains/EQ update the running engine in place.
        AppState.shared.$config
            .map { (c: Config) -> [Double] in
                let head: [Double] = [c.eqEnabled ? 1 : 0, c.eqPreamp, c.audioBoost, c.audioBalance]
                return head + c.eqBands
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.apply() }
            .store(in: &cancellables)
        // Turning per-app volume on/off changes which apps get their own tap.
        AppState.shared.$config
            .map(\.perAppVolume)
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)

        // Switching speakers/headphones: rebuild on the new output.
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            let isDefault = selector == kAudioHardwarePropertyDefaultOutputDevice
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.refreshOutputs()
                if isDefault { self?.rebuild() }
            }
            listeners.append(block)
            AudioObjectAddPropertyListenerBlock(system, &addr, .main, block)
        }
    }

    func stopAll() {
        timer?.invalidate()
        timer = nil
        cancellables.removeAll()
        tearDown()
    }

    // MARK: Per-app volume

    func gain(for bundleID: String) -> Double {
        AppState.shared.config.appVolumes[bundleID] ?? 1
    }

    func setGain(_ value: Double, for bundleID: String) {
        let v = (value * 100).rounded() / 100
        let wasCustom = AppState.shared.config.appVolumes[bundleID] != nil
        if abs(v - 1) < 0.01 {
            AppState.shared.config.appVolumes[bundleID] = nil
        } else {
            AppState.shared.config.appVolumes[bundleID] = v
        }
        let isCustom = AppState.shared.config.appVolumes[bundleID] != nil
        // Starting/stopping custom volume for an app changes the taps; otherwise just update gains.
        if wasCustom != isCustom { rebuild() } else { apply() }
    }

    func toggleMute(_ bundleID: String) {
        setGain(gain(for: bundleID) == 0 ? 1 : 0, for: bundleID)
    }

    // MARK: System volume and output

    func systemVolume() -> Double { Double(SystemVolume.get() ?? 0.5) }
    func setSystemVolume(_ v: Double) { SystemVolume.set(Float(v)) }

    func setOutput(_ id: AudioObjectID) {
        AudioProcesses.setDefaultOutput(id)
        refreshOutputs()
    }

    func refreshOutputs() {
        let list = AudioProcesses.outputDevices()
        if list != outputs { outputs = list }
        let cur = AudioProcesses.defaultOutputDevice() ?? AudioObjectID(kAudioObjectUnknown)
        if cur != currentOutput { currentOutput = cur }
    }

    // MARK: EQ

    func applyPreset(_ name: String) {
        let cfg = AppState.shared.config
        let gains = Equalizer.presets.first { $0.name == name }?.gains ?? cfg.eqCustomPresets[name]
        guard let gains else { return }
        AppState.shared.config.eqBands = gains
        AppState.shared.config.eqPresetName = name
        AppState.shared.config.eqEnabled = true
        autoPreamp()
    }

    func setBand(_ index: Int, to db: Double) {
        guard index >= 0, index < 10 else { return }
        AppState.shared.config.eqBands[index] = (db * 2).rounded() / 2
        AppState.shared.config.eqPresetName = "Manual"
        if !AppState.shared.config.eqEnabled { AppState.shared.config.eqEnabled = true }
        autoPreamp()
    }

    func autoPreamp() {
        guard AppState.shared.config.eqAutoPreamp else { return }
        let top = AppState.shared.config.eqBands.max() ?? 0
        AppState.shared.config.eqPreamp = -max(0, top)
    }

    func saveCustomPreset(named name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        AppState.shared.config.eqCustomPresets[n] = AppState.shared.config.eqBands
        AppState.shared.config.eqPresetName = n
    }

    func deleteCustomPreset(named name: String) {
        AppState.shared.config.eqCustomPresets[name] = nil
        if AppState.shared.config.eqPresetName == name { AppState.shared.config.eqPresetName = "Manual" }
    }

    // MARK: Engine

    private var needsEngine: Bool {
        let c = AppState.shared.config
        let eqActive = c.eqEnabled && (c.eqBands.contains { abs($0) >= 0.25 } || abs(c.eqPreamp) >= 0.25)
        return (c.perAppVolume && !c.appVolumes.isEmpty) || eqActive || c.audioBoost > 0.005 || abs(c.audioBalance) > 0.01
    }

    func refresh() {
        guard #available(macOS 14.2, *) else { return }
        let list = AudioProcesses.apps()
        if list != apps { apps = list }
        // A custom-volume app opened a new helper (new tab, etc.): rebuild so it's included.
        if let e = engine as? MixerEngine, e.processSignature != signature(list) {
            rebuild()
        } else if engine == nil, needsEngine, Date() > retryAt {
            rebuild()
        }
    }

    @available(macOS 14.2, *)
    private func signature(_ list: [MixerApp]) -> [AudioObjectID] {
        customAppIDs(list).flatMap { id in list.first { $0.bundleID == id }?.processObjects.sorted() ?? [] }
    }

    @available(macOS 14.2, *)
    private func customAppIDs(_ list: [MixerApp]) -> [String] {
        guard AppState.shared.config.perAppVolume else { return [] }
        let custom = AppState.shared.config.appVolumes
        return list.map(\.bundleID).filter { custom[$0] != nil }.sorted()
    }

    /// Gains and EQ for the engine, computed on the main thread.
    private func dspConfig(customApps: [String], sampleRate: Double) -> DSPConfig {
        let c = AppState.shared.config
        let gains: [Float] = [1] + customApps.map { Float(c.appVolumes[$0] ?? 1) }
        let eqOn = c.eqEnabled && c.eqBands.contains { abs($0) >= 0.25 }
        let coeffs = Equalizer.frequencies.enumerated().map { i, f in
            Equalizer.peaking(freq: f, gainDB: i < c.eqBands.count ? c.eqBands[i] : 0, sampleRate: sampleRate)
        }
        let preampDB = c.eqEnabled ? c.eqPreamp : 0
        let boost = 1 + c.audioBoost              // up to 2× (100% boost)
        let pre = Float(pow(10, preampDB / 20) * boost)
        let bal = max(-1, min(1, c.audioBalance))
        return DSPConfig(tapGains: gains, eqOn: eqOn, coeffs: coeffs, preamp: pre,
                         leftGain: Float(bal > 0 ? 1 - bal : 1), rightGain: Float(bal < 0 ? 1 + bal : 1))
    }

    /// Push new gains/EQ into the running engine, or start/stop it as needed.
    private func apply() {
        guard #available(macOS 14.2, *) else { return }
        if let e = engine as? MixerEngine {
            if !needsEngine { tearDown(); return }
            e.update(dspConfig(customApps: e.customApps, sampleRate: e.sampleRate))
        } else if needsEngine {
            rebuild()
        }
    }

    private func rebuild() {
        guard #available(macOS 14.2, *) else { return }
        tearDown()
        guard needsEngine else { return }
        let list = AudioProcesses.apps()
        if list != apps { apps = list }
        let ids = customAppIDs(list)
        let procs = ids.map { id in list.first { $0.bundleID == id }?.processObjects ?? [] }
        let e = MixerEngine(customApps: ids, processSignature: signature(list),
                            config: dspConfig(customApps: ids, sampleRate: 48_000))
        do {
            try e.start(appProcesses: procs)
            e.update(dspConfig(customApps: ids, sampleRate: e.sampleRate))
            engine = e
            isProcessing = true
            lastError = nil
        } catch {
            retryAt = Date().addingTimeInterval(10)
            lastError = error.localizedDescription
            LiveActivityCenter.shared.flash(symbol: "exclamationmark.triangle.fill", text: error.localizedDescription, seconds: 4)
        }
    }

    private func tearDown() {
        if #available(macOS 14.2, *) { (engine as? MixerEngine)?.stop() }
        engine = nil
        if isProcessing { isProcessing = false }
    }
}

// MARK: - Controls

/// A vertical fader like a mixing desk's.
struct VerticalSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var tint: Color
    var center: Double? = nil      // draw the fill from here (e.g. 0 dB)
    var onEditingChanged: (Double) -> Void = { _ in }

    var body: some View {
        GeometryReader { g in
            let h = g.size.height
            let knob: CGFloat = 14
            let span = range.upperBound - range.lowerBound
            let frac = CGFloat((value - range.lowerBound) / span)
            let y = (h - knob) * (1 - frac)
            let base = center.map { CGFloat(($0 - range.lowerBound) / span) } ?? 0
            let baseY = (h - knob) * (1 - base) + knob / 2
            ZStack(alignment: .top) {
                // Tick marks
                VStack(spacing: 0) {
                    ForEach(0..<9, id: \.self) { _ in
                        Rectangle().fill(Color.white.opacity(0.08)).frame(width: 16, height: 1)
                        Spacer(minLength: 0)
                    }
                    Rectangle().fill(Color.white.opacity(0.08)).frame(width: 16, height: 1)
                }
                Capsule().fill(Color.black.opacity(0.6)).frame(width: 4)
                Capsule()
                    .fill(tint)
                    .frame(width: 4, height: abs(baseY - (y + knob / 2)))
                    .offset(y: min(baseY, y + knob / 2))
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color(white: 0.18))
                    .overlay(Rectangle().fill(tint).frame(height: 1.5))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.black.opacity(0.6)))
                    .frame(width: 22, height: knob)
                    .offset(y: y)
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let f = 1 - min(1, max(0, (drag.location.y - knob / 2) / max(1, h - knob)))
                let v = range.lowerBound + Double(f) * span
                value = v
                onEditingChanged(v)
            })
            .onTapGesture(count: 2) {
                let reset = center ?? range.lowerBound
                value = reset
                onEditingChanged(reset)
            }
        }
    }
}

/// A round knob: drag up/down to turn, double-click to reset.
struct Knob: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var tint: Color
    var resetTo: Double
    var bipolar = false
    @State private var dragStart: Double?

    var body: some View {
        let span = range.upperBound - range.lowerBound
        let frac = (value - range.lowerBound) / span
        let startAngle = 135.0, sweep = 270.0
        ZStack {
            Circle().fill(Color(white: 0.16))
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(Color.white.opacity(0.1), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(startAngle))
            Circle()
                .trim(from: bipolar ? min(0.375, frac * 0.75) : 0, to: bipolar ? max(0.375, frac * 0.75) : frac * 0.75)
                .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(startAngle))
            Circle().fill(tint.opacity(0.75)).padding(9)
            Capsule()
                .fill(Color.black.opacity(0.75))
                .frame(width: 3, height: 12)
                .offset(y: -12)
                .rotationEffect(.degrees(startAngle + 90 + frac * sweep))
        }
        .frame(width: 58, height: 58)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { d in
                if dragStart == nil { dragStart = value }
                let delta = -Double(d.translation.height) / 160 * span
                value = min(range.upperBound, max(range.lowerBound, (dragStart ?? value) + delta))
            }
            .onEnded { _ in dragStart = nil })
        .onTapGesture(count: 2) { value = resetTo }
    }
}

// MARK: - Full mixer (window)

struct MixerWindowView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var mixer = MixerModel.shared
    @State private var volume: Double = 0.5
    @State private var newPresetName = ""
    @State private var naming = false

    var body: some View {
        VStack(spacing: 0) {
            if !MixerModel.isSupported {
                Text("The mixer needs macOS 14.2 or later.").padding(40)
            } else {
                topSection
                divider
                appMixer
                divider
                eqSection
                Spacer(minLength: 0)
                divider
                outputPicker
            }
        }
        .frame(width: 440, height: 740)
        .background(Color(white: 0.12))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onAppear {
            mixer.start()
            mixer.visible += 1
            volume = mixer.systemVolume()
        }
        .onDisappear { mixer.visible = max(0, mixer.visible - 1) }
        .onReceive(VolumeMonitor.shared.$lastChange) { _ in volume = mixer.systemVolume() }
    }

    private var divider: some View { Rectangle().fill(Color.black.opacity(0.5)).frame(height: 1) }

    private func header(_ title: String, on: Binding<Bool>?) -> some View {
        HStack {
            if let on {
                Toggle("", isOn: on).toggleStyle(.switch).labelsHidden().controlSize(.mini)
            }
            Spacer()
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            if on != nil { Color.clear.frame(width: 32, height: 1) }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Color(white: 0.09))
    }

    // Volume / Boost / Balance
    private var topSection: some View {
        HStack(spacing: 0) {
            VStack(spacing: 6) {
                Text("Volume").font(.system(size: 12, weight: .semibold))
                HStack(spacing: 14) {
                    valueBox("\(Int((volume * 100).rounded()))%", "Volume")
                    Knob(value: Binding(get: { volume }, set: { volume = $0; mixer.setSystemVolume($0) }),
                         range: 0...1, tint: .green, resetTo: 0.5)
                    valueBox("\(Int((state.config.audioBoost * 100).rounded()))%", "Boost")
                }
                Slider(value: $state.config.audioBoost, in: 0...1) { Text("Boost") }
                    .labelsHidden()
                    .controlSize(.mini)
                    .frame(width: 150)
                    .help("Boost: up to 2× louder than macOS allows. Double-click the knob to reset volume.")
            }
            .frame(maxWidth: .infinity)
            Rectangle().fill(Color.black.opacity(0.5)).frame(width: 1)
            VStack(spacing: 6) {
                Text("Balance").font(.system(size: 12, weight: .semibold))
                HStack(spacing: 14) {
                    valueBox("\(Int((min(1, 1 - state.config.audioBalance) * 100).rounded()))%", "Left")
                    Knob(value: $state.config.audioBalance, range: -1...1, tint: .green, resetTo: 0, bipolar: true)
                    valueBox("\(Int((min(1, 1 + state.config.audioBalance) * 100).rounded()))%", "Right")
                }
                Text("Double-click to center").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 12)
        .background(Color(white: 0.14))
    }

    private func valueBox(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.75))
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 48, height: 18)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.45)))
        }
    }

    // App Mixer
    private var appMixer: some View {
        VStack(spacing: 0) {
            header("App Mixer", on: $state.config.perAppVolume)
            if state.config.perAppVolume {
                if mixer.apps.isEmpty {
                    Text("Apps that play sound show up here.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(height: 210)
                } else {
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(spacing: 2) {
                            ForEach(mixer.apps) { app in AppChannel(app: app) }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                    }
                    .frame(height: 210)
                }
            }
            if let err = mixer.lastError {
                Text(err).font(.system(size: 10)).foregroundStyle(.orange).padding(6)
            }
        }
    }

    // EQ
    private var eqSection: some View {
        VStack(spacing: 8) {
            header("Equalizer", on: $state.config.eqEnabled)
            HStack(spacing: 6) {
                Picker("", selection: Binding(get: { state.config.eqPresetName },
                                              set: { mixer.applyPreset($0) })) {
                    if state.config.eqPresetName == "Manual" { Text("Manual").tag("Manual") }
                    ForEach(Equalizer.presets, id: \.name) { p in Text(p.name).tag(p.name) }
                    if !state.config.eqCustomPresets.isEmpty {
                        Divider()
                        ForEach(state.config.eqCustomPresets.keys.sorted(), id: \.self) { n in Text(n).tag(n) }
                    }
                }
                .labelsHidden()
                Button {
                    newPresetName = ""
                    naming = true
                } label: { Image(systemName: "plus") }
                .help("Save the current curve as a preset")
                Button {
                    mixer.deleteCustomPreset(named: state.config.eqPresetName)
                } label: { Image(systemName: "minus") }
                .disabled(state.config.eqCustomPresets[state.config.eqPresetName] == nil)
                .help("Delete this saved preset")
            }
            .padding(.horizontal, 12)
            .popover(isPresented: $naming) {
                HStack {
                    TextField("Preset name", text: $newPresetName)
                        .frame(width: 160)
                        .onSubmit { mixer.saveCustomPreset(named: newPresetName); naming = false }
                    Button("Save") { mixer.saveCustomPreset(named: newPresetName); naming = false }
                }
                .padding(10)
            }

            HStack(spacing: 8) {
                Text("Preamp").font(.system(size: 11, weight: .medium))
                Slider(value: Binding(get: { state.config.eqPreamp },
                                      set: { state.config.eqPreamp = ($0 * 2).rounded() / 2; state.config.eqAutoPreamp = false }),
                       in: -12...12)
                    .controlSize(.mini)
                Text(String(format: "%+.1fdB", state.config.eqPreamp))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 52)
                Toggle("Auto", isOn: $state.config.eqAutoPreamp)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .onChange(of: state.config.eqAutoPreamp) { _, on in if on { mixer.autoPreamp() } }
            }
            .padding(.horizontal, 12)

            HStack(spacing: 0) {
                ForEach(0..<10, id: \.self) { i in
                    VStack(spacing: 4) {
                        Text(Equalizer.labels[i]).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                        VerticalSlider(value: Binding(get: { state.config.eqBands[i] }, set: { mixer.setBand(i, to: $0) }),
                                       range: -Equalizer.maxGain...Equalizer.maxGain,
                                       tint: state.config.eqEnabled ? .green : .gray, center: 0)
                        Text(String(format: "%+.1f", state.config.eqBands[i]))
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 200)
            .padding(.horizontal, 8)
            .opacity(state.config.eqEnabled ? 1 : 0.5)
        }
        .padding(.bottom, 8)
    }

    // Output device
    private var outputPicker: some View {
        HStack(spacing: 8) {
            let current = mixer.outputs.first { $0.id == mixer.currentOutput }
            Image(systemName: current?.symbol ?? "speaker.wave.2.fill")
            Picker("", selection: Binding(get: { mixer.currentOutput }, set: { mixer.setOutput($0) })) {
                ForEach(mixer.outputs) { d in Text(d.name).tag(d.id) }
            }
            .labelsHidden()
            if mixer.isProcessing {
                Label("Processing", systemImage: "waveform")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.green)
                    .help("Driftdock is applying your mixer settings")
            }
        }
        .padding(12)
        .background(Color(white: 0.09))
    }
}

/// One app's column in the full mixer.
struct AppChannel: View {
    @ObservedObject var mixer = MixerModel.shared
    let app: MixerApp

    var body: some View {
        let value = mixer.gain(for: app.bundleID)
        VStack(spacing: 6) {
            Button { mixer.toggleMute(app.bundleID) } label: {
                Image(nsImage: NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID)
                        .map { IconCache.icon(for: $0.path) } ?? NSImage())
                    .resizable()
                    .frame(width: 30, height: 30)
                    .opacity(value == 0 ? 0.35 : 1)
                    .overlay(alignment: .bottomTrailing) {
                        if value == 0 {
                            Image(systemName: "speaker.slash.fill").font(.system(size: 9)).foregroundStyle(.red)
                        } else if app.isPlaying {
                            Circle().fill(Color.green).frame(width: 7, height: 7)
                        }
                    }
            }
            .buttonStyle(.plain)
            .help("\(app.name): click to mute")
            VerticalSlider(value: Binding(get: { value }, set: { mixer.setGain($0, for: app.bundleID) }),
                           range: 0...2, tint: value > 1 ? .orange : .green, center: nil)
            Text("\(Int((value * 100).rounded()))%")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 46, height: 18)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.45)))
        }
        .frame(width: 54)
    }
}

// MARK: - Compact mixer (notch tab)

struct MixerView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var mixer = MixerModel.shared
    var dark = true
    @State private var volume: Double = 0.5

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !MixerModel.isSupported {
                Text("The mixer needs macOS 14.2 or later.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 11))
                    Slider(value: Binding(get: { volume }, set: { volume = $0; mixer.setSystemVolume($0) }), in: 0...1)
                        .controlSize(.mini)
                    Menu {
                        ForEach(Equalizer.presets, id: \.name) { p in
                            Button(p.name) { mixer.applyPreset(p.name) }
                        }
                        ForEach(state.config.eqCustomPresets.keys.sorted(), id: \.self) { n in
                            Button(n) { mixer.applyPreset(n) }
                        }
                        Divider()
                        Toggle("Equalizer On", isOn: $state.config.eqEnabled)
                    } label: {
                        Text("EQ: \(state.config.eqEnabled ? state.config.eqPresetName : "Off")")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Button { MixerPanelController.shared.toggle() } label: {
                        Image(systemName: "slider.vertical.3").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("Open the full mixer")
                }
                if !state.config.perAppVolume {
                    Text("Per-app volume is off. Turn it on in the full mixer.").font(.system(size: 11)).foregroundStyle(.secondary)
                } else if mixer.apps.isEmpty {
                    Text("Apps that play sound show up here.").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(spacing: 5) {
                            ForEach(mixer.apps) { app in MixerRow(app: app) }
                        }
                    }
                }
                if let err = mixer.lastError {
                    Text(err).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2)
                }
            }
        }
        .onAppear {
            mixer.start()
            mixer.visible += 1
            volume = mixer.systemVolume()
        }
        .onDisappear { mixer.visible = max(0, mixer.visible - 1) }
        .onReceive(VolumeMonitor.shared.$lastChange) { _ in volume = mixer.systemVolume() }
    }
}

struct MixerRow: View {
    @ObservedObject var mixer = MixerModel.shared
    let app: MixerApp

    var body: some View {
        let value = mixer.gain(for: app.bundleID)
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID)
                    .map { IconCache.icon(for: $0.path) } ?? NSImage())
                .resizable()
                .frame(width: 18, height: 18)
                .overlay(alignment: .bottomTrailing) {
                    if app.isPlaying { Circle().fill(Color.green).frame(width: 5, height: 5) }
                }
            Text(app.name).font(.system(size: 11, weight: .medium)).lineLimit(1).frame(width: 86, alignment: .leading)
            Button { mixer.toggleMute(app.bundleID) } label: {
                Image(systemName: value == 0 ? "speaker.slash.fill" : (value > 1 ? "speaker.wave.3.fill" : "speaker.wave.2.fill"))
                    .font(.system(size: 10))
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            Slider(value: Binding(get: { value }, set: { mixer.setGain($0, for: app.bundleID) }), in: 0...2)
                .controlSize(.mini)
            Text("\(Int((value * 100).rounded()))%")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
                .foregroundStyle(value > 1 ? Color.orange : Color.primary)
        }
    }
}

/// The full mixer window (menu bar → Volume Mixer, launcher, or the notch).
final class MixerPanelController: NSObject, NSWindowDelegate {
    static let shared = MixerPanelController()
    private var window: NSWindow?

    func toggle() {
        if let window, window.isVisible {
            window.orderOut(nil)
            return
        }
        let w = window ?? makeWindow()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: MixerWindowView().environmentObject(AppState.shared))
        let w = NSWindow(contentViewController: host)
        w.title = "Driftdock Mixer"
        w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.setContentSize(NSSize(width: 440, height: 740))
        w.center()
        w.delegate = self
        return w
    }
}
