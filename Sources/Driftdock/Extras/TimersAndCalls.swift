import SwiftUI
import AppKit
import CoreAudio
import AudioToolbox

// MARK: - Timers and stopwatches

final class TimerCenter: ObservableObject {
    static let shared = TimerCenter()

    struct Item: Identifiable, Equatable {
        enum Kind: Equatable { case timer, stopwatch }
        let id = UUID()
        let kind: Kind
        var label: String
        var duration: TimeInterval          // timers only
        var accumulated: TimeInterval = 0   // time banked before the current run
        var startedAt: Date? = Date()       // nil while paused

        var running: Bool { startedAt != nil }

        func elapsed(at now: Date = Date()) -> TimeInterval {
            accumulated + (startedAt.map { now.timeIntervalSince($0) } ?? 0)
        }

        func remaining(at now: Date = Date()) -> TimeInterval {
            max(0, duration - elapsed(at: now))
        }

        /// 0…1, how far along a timer is.
        func progress(at now: Date = Date()) -> Double {
            duration > 0 ? min(1, elapsed(at: now) / duration) : 0
        }
    }

    @Published private(set) var items: [Item] = []
    private var ticker: Timer?

    private init() {}

    /// The one the notch shows: the running timer that ends soonest, else a running stopwatch.
    var featured: Item? {
        let now = Date()
        let timers = items.filter { $0.kind == .timer && $0.running }.sorted { $0.remaining(at: now) < $1.remaining(at: now) }
        return timers.first ?? items.first { $0.kind == .stopwatch && $0.running }
    }

    func addTimer(_ seconds: TimeInterval, label: String? = nil) {
        guard seconds >= 1 else { return }
        items.append(Item(kind: .timer, label: label ?? Self.describe(seconds), duration: seconds))
        ensureTicking()
        LiveActivityCenter.shared.flash(symbol: "timer", text: "\(Self.describe(seconds)) timer started")
    }

    func addStopwatch() {
        items.append(Item(kind: .stopwatch, label: "Stopwatch", duration: 0))
        ensureTicking()
    }

    func toggle(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if let start = items[i].startedAt {
            items[i].accumulated += Date().timeIntervalSince(start)
            items[i].startedAt = nil
        } else {
            items[i].startedAt = Date()
            ensureTicking()
        }
    }

    func reset(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].accumulated = 0
        items[i].startedAt = items[i].running ? Date() : nil
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    private func ensureTicking() {
        guard ticker == nil else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func tick() {
        let now = Date()
        for item in items where item.kind == .timer && item.running && item.remaining(at: now) <= 0 {
            items.removeAll { $0.id == item.id }
            NSSound(named: NSSound.Name("Glass"))?.play()
            LiveActivityCenter.shared.showBanner(.init(symbol: "timer", tint: .orange, title: "Time's up",
                                                       value: nil, subtitle: "\(item.label) timer finished",
                                                       trailing: "bell.fill"), seconds: 6)
        }
        if !items.contains(where: \.running) {
            ticker?.invalidate()
            ticker = nil
        }
        // Views show live times with their own TimelineView; no need to publish every tick.
    }

    // MARK: Text

    static func describe(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s % 3600 == 0 { return "\(s / 3600) hr" }
        if s % 60 == 0 { return "\(s / 60) min" }
        if s < 60 { return "\(s) sec" }
        return "\(s / 60) min \(s % 60) sec"
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.up))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// "10m", "10 min", "1h30m", "90s", "timer 5", "5 minute timer" → seconds.
    static func parse(_ text: String) -> TimeInterval? {
        var t = text.lowercased()
        for word in ["set a ", "set ", "start a ", "start ", "timer for ", "timer ", " timer", "for "] {
            t = t.replacingOccurrences(of: word, with: " ")
        }
        t = t.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if let n = Double(t), n > 0, n <= 600 { return n * 60 }   // bare number = minutes

        var total = 0.0
        var number = ""
        var matched = false
        var unit = ""
        func flush() -> Bool {
            guard let n = Double(number) else { return unit.isEmpty }
            switch unit {
            case "h", "hr", "hrs", "hour", "hours": total += n * 3600
            case "m", "min", "mins", "minute", "minutes", "": total += n * 60
            case "s", "sec", "secs", "second", "seconds": total += n
            default: return false
            }
            matched = true
            number = ""
            unit = ""
            return true
        }
        for ch in t {
            if ch.isNumber || ch == "." {
                if !unit.isEmpty { if !flush() { return nil } }
                number.append(ch)
            } else if ch.isLetter {
                unit.append(ch)
            } else if ch == " " {
                continue
            } else {
                return nil
            }
        }
        if !flush() { return nil }
        return matched && total >= 1 && total <= 24 * 3600 ? total : nil
    }
}

// MARK: - Calls

/// Notices when an app is using the microphone for a call (FaceTime, Zoom, Teams, Meet,
/// Discord, Slack, WhatsApp…) and how long it's been going. macOS doesn't let apps see
/// incoming calls before they're answered, so this starts once the call does.
final class CallMonitor: ObservableObject {
    static let shared = CallMonitor()

    struct Call: Equatable {
        let bundleID: String
        let name: String
        let startedAt: Date
    }

    @Published private(set) var call: Call?
    @Published private(set) var micMuted = false
    private var timer: Timer?

    static let callApps: Set<String> = [
        "com.apple.FaceTime", "us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2",
        "com.hnc.Discord", "com.tinyspeck.slackmacgap", "net.whatsapp.WhatsApp", "desktop.WhatsApp",
        "com.cisco.webexmeetingsapp", "com.webex.meetingmanager", "ru.keepcoder.Telegram", "com.skype.skype",
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "com.microsoft.edgemac",
        "org.mozilla.firefox", "com.brave.Browser", "com.apple.mobilephone",
    ]

    private init() {}

    func start() {
        guard timer == nil else { return }
        check()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.check() }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        call = nil
    }

    private static func inputDevice() -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    private func check() {
        // Cheap test first: is anything recording at all?
        guard let mic = Self.inputDevice() else { end(); return }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(mic, &addr, 0, nil, &size, &running) == noErr, running != 0 else { end(); return }

        guard #available(macOS 14.2, *) else { return }
        let recording = AudioProcesses.apps().filter { $0.isRecording && Self.callApps.contains($0.bundleID) }
        guard let app = recording.first else { end(); return }
        if call?.bundleID != app.bundleID {
            call = Call(bundleID: app.bundleID, name: app.name, startedAt: Date())
            micMuted = Self.isMicMuted()
            LiveActivityCenter.shared.flash(symbol: "phone.fill", text: "Call in \(app.name)")
        }
    }

    private func end() {
        if call != nil { call = nil }
    }

    // MARK: Microphone mute

    private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeInput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func isMicMuted() -> Bool {
        guard let mic = inputDevice() else { return false }
        var addr = muteAddress()
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(mic, &addr, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    /// Mutes the Mac's microphone for every app (the call app's own mute button is separate).
    func toggleMic() {
        guard let mic = Self.inputDevice() else { return }
        var addr = Self.muteAddress()
        var value: UInt32 = micMuted ? 0 : 1
        let status = AudioObjectSetPropertyData(mic, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        if status == noErr {
            micMuted.toggle()
            LiveActivityCenter.shared.flash(symbol: micMuted ? "mic.slash.fill" : "mic.fill",
                                            text: micMuted ? "Microphone muted" : "Microphone on")
        } else {
            LiveActivityCenter.shared.flash(symbol: "mic.fill", text: "This microphone can't be muted here")
        }
    }

    func showCallApp() {
        guard let id = call?.bundleID,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { return }
        app.activate(options: [.activateAllWindows])
    }
}

// MARK: - Notch views

/// Orange ring that empties as a timer runs (with an icon inside), like Droppy.
struct ProgressRing: View {
    let progress: Double
    let color: Color
    var symbol: String? = nil

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.25), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.001, 1 - progress))
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let symbol {
                Image(systemName: symbol).font(.system(size: 8, weight: .bold)).foregroundStyle(color)
            }
        }
    }
}

/// The notch's Timers tab: everything running, plus quick ways to start more.
struct NotchTimers: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var timers = TimerCenter.shared
    @State private var custom = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach([1, 5, 10, 25], id: \.self) { m in
                    quick("\(m)m") { timers.addTimer(Double(m) * 60) }
                }
                quick("Stopwatch", symbol: "stopwatch") { timers.addStopwatch() }
                TextField("e.g. 12m", text: $custom)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .onSubmit {
                        if let s = TimerCenter.parse(custom) { timers.addTimer(s) }
                        custom = ""
                    }
            }
            if timers.items.isEmpty {
                Text("No timers running. Start one here, or type \"timer 10m\" in the launcher (⌥Space).")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                ScrollView {
                    TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                        VStack(spacing: 6) {
                            ForEach(timers.items) { item in row(item, now: ctx.date) }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func quick(_ title: String, symbol: String = "timer", action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Capsule().fill(Color.orange.opacity(0.22)))
                .foregroundStyle(.orange)
        }
        .buttonStyle(.plain)
    }

    private func row(_ item: TimerCenter.Item, now: Date) -> some View {
        HStack(spacing: 10) {
            if item.kind == .timer {
                ProgressRing(progress: item.progress(at: now), color: .orange).frame(width: 20, height: 20)
            } else {
                Image(systemName: "stopwatch").foregroundStyle(.orange).frame(width: 20)
            }
            Text(item.label).font(.system(size: 12, weight: .semibold))
            Spacer()
            Text(TimerCenter.clock(item.kind == .timer ? item.remaining(at: now) : item.elapsed(at: now)))
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.orange)
            Button { timers.toggle(item.id) } label: {
                Image(systemName: item.running ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .buttonStyle(.plain)
            Button { timers.reset(item.id) } label: {
                Image(systemName: "arrow.counterclockwise").frame(width: 18)
            }
            .buttonStyle(.plain)
            Button { timers.remove(item.id) } label: {
                Image(systemName: "xmark").frame(width: 18)
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 11, weight: .bold))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}
