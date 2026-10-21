import Foundation
import AppKit
import CoreAudio
import AudioToolbox
import IOKit.pwr_mgt
import Combine
import SwiftUI

/// What the closed notch is showing besides music/battery: volume, downloads, and short messages.
final class LiveActivityCenter: ObservableObject {
    static let shared = LiveActivityCenter()

    struct Flash: Equatable {
        let symbol: String
        let text: String
        let id = UUID()
    }

    @Published private(set) var flash: Flash?
    private var flashWork: DispatchWorkItem?

    /// A two-line notice that grows the notch downward (Full Battery, AirPods connected…).
    struct Banner: Equatable {
        let symbol: String
        let tint: Color
        let title: String
        var value: String? = nil
        var subtitle: String
        var trailing: String? = "checkmark"
        let id = UUID()
    }

    /// "AirPods connected" style: device icon on the left, a battery ring on the right.
    struct DeviceNotice: Equatable {
        let name: String
        let symbol: String
        let level: Int?
        var left: Int? = nil
        var right: Int? = nil
        var caseLevel: Int? = nil
        let id = UUID()
    }

    @Published private(set) var device: DeviceNotice?
    private var deviceWork: DispatchWorkItem?

    func showDevice(_ d: DeviceNotice, seconds: Double = 5) {
        deviceWork?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { device = d }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { self?.device = nil }
        }
        deviceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    @Published private(set) var banner: Banner?
    private var bannerWork: DispatchWorkItem?

    func showBanner(_ b: Banner, seconds: Double = 4) {
        guard AppState.shared.config.notchBanners else {
            flash(symbol: b.symbol, text: [b.title, b.value].compactMap { $0 }.joined(separator: " "))
            return
        }
        bannerWork?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { banner = b }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { self?.banner = nil }
        }
        bannerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private init() {}

    /// Shows a short message beside the notch for a couple of seconds ("Copied", "File ready"…).
    func flash(symbol: String, text: String, seconds: Double = 2.4) {
        flashWork?.cancel()
        flash = Flash(symbol: symbol, text: text)
        let work = DispatchWorkItem { [weak self] in self?.flash = nil }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

// MARK: - Volume

/// Follows the system output volume through CoreAudio so the notch can show changes.
/// (It shows alongside the macOS volume overlay; replacing that needs Accessibility.)
final class VolumeMonitor: ObservableObject {
    static let shared = VolumeMonitor()

    @Published private(set) var volume: Float = 0
    @Published private(set) var muted = false
    /// Set whenever the volume or mute changes; the notch shows the bar for a moment after.
    @Published private(set) var lastChange: Date?
    /// True for a moment after each change, while the notch shows the level.
    @Published private(set) var showing = false
    private var hideWork: DispatchWorkItem?

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var attached = Set<AudioObjectID>()
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        var defaultAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddr, .main) { [weak self] _, _ in
            self?.attachToDefaultDevice()
        }
        attachToDefaultDevice()
    }

    private func attachToDefaultDevice() {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != device else { return }
        device = id
        defer { read() }
        guard !attached.contains(id) else { return }   // already listening to this device
        attached.insert(id)
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var a = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                               mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(id, &a, .main) { [weak self] _, _ in
                guard let self, self.device == id else { return }
                self.read()
                self.lastChange = Date()
                self.showing = true
                self.hideWork?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.showing = false }
                self.hideWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
            }
        }
        read()
    }

    private func read() {
        var vol: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                           mScope: kAudioDevicePropertyScopeOutput,
                                           mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(device, &a, 0, nil, &size, &vol) == noErr { volume = vol }
        var mute: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        a.mSelector = kAudioDevicePropertyMute
        if AudioObjectGetPropertyData(device, &a, 0, nil, &size, &mute) == noErr { muted = mute != 0 }
    }
}

// MARK: - Downloads

/// Notices browser downloads in ~/Downloads (Safari, Chrome, Firefox, Edge, Arc…).
final class DownloadsMonitor: ObservableObject {
    static let shared = DownloadsMonitor()

    /// Names of downloads in progress (without the temporary extension).
    @Published private(set) var active: [String] = []
    /// A download that just finished, shown briefly with a checkmark.
    @Published private(set) var finished: URL?

    private var timer: Timer?
    private let partial: Set<String> = ["download", "crdownload", "part", "partial", "opdownload"]
    private let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")

    private init() {}

    private var watcher: DispatchSourceFileSystemObject?

    func start() {
        guard watcher == nil else { return }
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { [weak self] in self?.scan() }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
        scan()
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        timer?.invalidate()
        timer = nil
        active = []
    }

    private func scan() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let now = names
            .filter { partial.contains(($0 as NSString).pathExtension.lowercased()) }
            .map { ($0 as NSString).deletingPathExtension }
        let gone = Set(active).subtracting(now)
        for name in gone {
            let done = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: done.path) {
                finished = done
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    if self?.finished == done { self?.finished = nil }
                }
            }
        }
        if now != active { active = now }
        // Poll once a second only while a download is in progress (to catch it finishing).
        if active.isEmpty {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.scan() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }
}

// MARK: - Stay Awake

/// Keeps the Mac and display awake, like `caffeinate -d`.
final class StayAwake: ObservableObject {
    static let shared = StayAwake()
    @Published private(set) var isOn = false
    private var assertion: IOPMAssertionID = 0

    private init() {}

    func toggle() { isOn ? turnOff() : turnOn() }

    func turnOn() {
        guard !isOn else { return }
        let ok = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                             IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                             "Driftdock Stay Awake" as CFString, &assertion)
        isOn = ok == kIOReturnSuccess
        if isOn { LiveActivityCenter.shared.flash(symbol: "cup.and.saucer.fill", text: "Staying awake") }
    }

    func turnOff() {
        guard isOn else { return }
        IOPMAssertionRelease(assertion)
        isOn = false
        LiveActivityCenter.shared.flash(symbol: "moon.zzz.fill", text: "Sleep allowed")
    }
}

// MARK: - Wiring

/// Keeps shortcuts, the shake-to-tray detector and the monitors in sync with Settings.
final class ExtrasController {
    private let state: AppState
    private var cancellable: AnyCancellable?

    private enum HotKeyID: UInt32 { case launcher = 1, clipboard = 2 }

    init(state: AppState) {
        self.state = state
        cancellable = state.$config
            .map { [$0.launcherHotkey, $0.clipboardHotkey, $0.shakeForTray, $0.notchVolumeHUD, $0.notchDownloads,
                    $0.devicesBattery, $0.snapHotkeys, $0.snapDrag, $0.perAppVolume, $0.dictationHotkey,
                    $0.replaceSystemHUD, $0.notchEnabled, $0.notchLiveCalls] }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.apply() } }
    }

    /// Key codes for ⌃⌥ snapping shortcuts.
    static let snapKeys: [(Int, SnapTarget)] = [
        (123, .leftHalf), (124, .rightHalf), (126, .topHalf), (125, .bottomHalf),
        (36, .maximize), (8, .center),
        (32, .topLeft), (34, .topRight), (38, .bottomLeft), (40, .bottomRight),
        (2, .leftThird), (3, .centerThird), (5, .rightThird), (14, .leftTwoThirds), (17, .rightTwoThirds),
    ]

    static let snapKeyNames: [SnapTarget: String] = [
        .leftHalf: "⌃⌥←", .rightHalf: "⌃⌥→", .topHalf: "⌃⌥↑", .bottomHalf: "⌃⌥↓",
        .maximize: "⌃⌥↩", .center: "⌃⌥C",
        .topLeft: "⌃⌥U", .topRight: "⌃⌥I", .bottomLeft: "⌃⌥J", .bottomRight: "⌃⌥K",
        .leftThird: "⌃⌥D", .centerThird: "⌃⌥F", .rightThird: "⌃⌥G", .leftTwoThirds: "⌃⌥E", .rightTwoThirds: "⌃⌥T",
    ]

    private func apply() {
        let cfg = state.config
        let hk = HotKeyCenter.shared
        if cfg.launcherHotkey {
            hk.register(id: HotKeyID.launcher.rawValue, keyCode: 49 /* space */, modifiers: 0x0800 /* option */) {
                LauncherController.shared.toggle()
            }
        } else {
            hk.unregister(id: HotKeyID.launcher.rawValue)
        }
        if cfg.clipboardHotkey {
            _ = ClipboardModel.shared // start recording history even if the dock widget is off
            hk.register(id: HotKeyID.clipboard.rawValue, keyCode: 9 /* V */, modifiers: 0x0100 | 0x0200 /* cmd+shift */) {
                ClipboardPickerController.shared.toggle()
            }
        } else {
            hk.unregister(id: HotKeyID.clipboard.rawValue)
        }
        FileTrayController.shared.setShakeEnabled(cfg.shakeForTray)
        if cfg.dictationHotkey {
            hk.register(id: 300, keyCode: 2 /* D */, modifiers: 0x0800 | 0x0200 /* option+shift */) {
                VoiceTranscriber.shared.toggle()
            }
        } else {
            hk.unregister(id: 300)
        }
        cfg.devicesBattery ? DevicesModel.shared.start() : DevicesModel.shared.stop()
        cfg.notchLiveCalls && cfg.notchEnabled ? CallMonitor.shared.start() : CallMonitor.shared.stop()
        MixerModel.shared.start()   // idles cheaply; only processes audio when a setting needs it
        DragSnapper.shared.setEnabled(cfg.snapDrag)

        // Window snapping: ⌃⌥ + key, like Rectangle.
        let ctrlOpt = 0x1000 | 0x0800
        for (i, (key, target)) in Self.snapKeys.enumerated() {
            let id = UInt32(100 + i)
            if cfg.snapHotkeys {
                hk.register(id: id, keyCode: key, modifiers: ctrlOpt) { WindowSnapper.shared.snapFocused(target) }
            } else {
                hk.unregister(id: id)
            }
        }
        if cfg.snapHotkeys {
            hk.register(id: 199, keyCode: 51 /* delete */, modifiers: ctrlOpt) { WindowSnapper.shared.restoreFocused() }
        } else {
            hk.unregister(id: 199)
        }
        if cfg.notchVolumeHUD || cfg.replaceSystemHUD { VolumeMonitor.shared.start() }
        // Only take over the keys when the notch is there to show the change.
        MediaKeyInterceptor.shared.setEnabled(cfg.replaceSystemHUD && cfg.notchEnabled)
        cfg.notchDownloads ? DownloadsMonitor.shared.start() : DownloadsMonitor.shared.stop()
    }
}
