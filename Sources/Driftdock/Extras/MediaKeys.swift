import AppKit
import CoreAudio
import AudioToolbox

/// Catches the volume and brightness keys before macOS does, changes the level itself,
/// and lets the notch show it instead of the system overlay. Needs Accessibility.
final class MediaKeyInterceptor {
    static let shared = MediaKeyInterceptor()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private(set) var isActive = false

    // NX_KEYTYPE_* values from IOKit's ev_keymap.h
    private let soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7

    private init() {}

    func setEnabled(_ on: Bool) {
        on ? start() : stop()
    }

    private func start() {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else {
            // Ask once, then wait quietly until access shows up (no repeated prompts).
            Paster.requestAccess()
            waitForAccess()
            return
        }
        let mask = CGEventMask(1) << 14 // NX_SYSDEFINED
        let callback: CGEventTapCallBack = { _, type, event, _ in
            MediaKeyInterceptor.shared.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: callback, userInfo: nil) else {
            LiveActivityCenter.shared.flash(symbol: "exclamationmark.triangle.fill", text: "Couldn't take over the volume keys")
            return
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = src
        isActive = true
    }

    private var waiting: Timer?

    private func waitForAccess() {
        guard waiting == nil else { return }
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] timer in
            guard AppState.shared.config.replaceSystemHUD else { timer.invalidate(); self?.waiting = nil; return }
            if AXIsProcessTrusted() {
                timer.invalidate()
                self?.waiting = nil
                self?.start()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        waiting = t
    }

    private func stop() {
        waiting?.invalidate()
        waiting = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        isActive = false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS turns slow taps off; turn it straight back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        let key = (ns.data1 & 0xFFFF0000) >> 16
        let flags = ns.data1 & 0x0000FFFF
        let isDown = ((flags & 0xFF00) >> 8) == 0xA
        // Shift+Option gives quarter steps, like macOS.
        let fine = ns.modifierFlags.contains(.shift) && ns.modifierFlags.contains(.option)
        let step: Float = fine ? 1.0 / 64 : 1.0 / 16

        switch key {
        case soundUp, soundDown, mute:
            guard SystemVolume.isControllable else { return Unmanaged.passUnretained(event) }
            if isDown {
                DispatchQueue.main.async {
                    switch key {
                    case self.soundUp: SystemVolume.change(by: step)
                    case self.soundDown: SystemVolume.change(by: -step)
                    default: SystemVolume.toggleMute()
                    }
                }
            }
            return nil // swallow: no system overlay
        case brightnessUp, brightnessDown:
            guard Brightness.isAvailable else { return Unmanaged.passUnretained(event) }
            if isDown {
                DispatchQueue.main.async {
                    Brightness.shared.change(by: key == self.brightnessUp ? step : -step)
                }
            }
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

// MARK: - Volume

enum SystemVolume {
    private static func device() -> AudioObjectID? {
        AudioProcesses.defaultOutputDevice()
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// Some outputs (HDMI, some USB) have no software volume; leave their keys alone.
    static var isControllable: Bool {
        guard let dev = device() else { return false }
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(dev, &addr)
            && AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr && settable.boolValue
    }

    static func get() -> Float? {
        guard let dev = device() else { return nil }
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var vol: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &vol) == noErr else { return nil }
        return vol
    }

    static func set(_ value: Float) {
        guard let dev = device() else { return }
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var v = max(0, min(1, value))
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        setMuted(v == 0)
    }

    static func change(by delta: Float) {
        guard let dev = device() else { return }
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var vol: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &vol)
        var new = max(0, min(1, vol + delta))
        // Snap to clean steps so 16 presses go from 0 to 100.
        new = (new * 64).rounded() / 64
        AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &new)
        setMuted(new == 0)
    }

    static func toggleMute() {
        guard let dev = device() else { return }
        var addr = address(kAudioDevicePropertyMute)
        var mute: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &mute)
        setMuted(mute == 0)
    }

    private static func setMuted(_ on: Bool) {
        guard let dev = device() else { return }
        var addr = address(kAudioDevicePropertyMute)
        var value: UInt32 = on ? 1 : 0
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}

// MARK: - Brightness

/// Built-in display brightness through DisplayServices (the same framework the
/// brightness keys use). Loaded at runtime; if it's missing, the keys pass through.
final class Brightness: ObservableObject {
    static let shared = Brightness()

    @Published private(set) var level: Float = 0.5
    @Published private(set) var showing = false
    private var hideWork: DispatchWorkItem?

    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getter: GetFn? = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }
        .map { unsafeBitCast($0, to: GetFn.self) }
    private static let setter: SetFn? = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }
        .map { unsafeBitCast($0, to: SetFn.self) }

    static var isAvailable: Bool { getter != nil && setter != nil }

    private init() {}

    /// The display under the pointer (or the main one).
    private var display: UInt32 {
        let p = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.screens.first
        return screen?.displayID ?? CGMainDisplayID()
    }

    func change(by delta: Float) {
        guard let get = Self.getter, let set = Self.setter else { return }
        var current: Float = 0.5
        _ = get(display, &current)
        let new = max(0, min(1, ((current + delta) * 64).rounded() / 64))
        if set(display, new) != 0 {
            // External displays don't support this; try the main display instead.
            _ = set(CGMainDisplayID(), new)
        }
        level = new
        showing = true
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.showing = false }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }
}
