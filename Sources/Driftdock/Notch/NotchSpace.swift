import AppKit

/// Keeps the notch on its own always-on-top Space, so macOS doesn't hide it during the
/// swipe animation between Spaces and full-screen apps. Uses WindowServer (SkyLight) calls
/// looked up at runtime; if they're unavailable this quietly does nothing.
final class NotchSpace {
    static let shared = NotchSpace()

    private typealias ConnFn = @convention(c) () -> Int32
    private typealias CreateFn = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias LevelFn = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias WindowsFn = @convention(c) (Int32, CFArray, CFArray) -> Int32
    private typealias SpacesFn = @convention(c) (Int32, CFArray) -> Int32
    private typealias DestroyFn = @convention(c) (Int32, UInt64) -> Int32

    private static let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static func fn<T>(_ names: [String], _ type: T.Type) -> T? {
        guard let lib else { return nil }
        for n in names { if let sym = dlsym(lib, n) { return unsafeBitCast(sym, to: type) } }
        return nil
    }

    private static let connection = fn(["SLSMainConnectionID", "_CGSDefaultConnection"], ConnFn.self)
    private static let create = fn(["SLSSpaceCreate", "CGSSpaceCreate"], CreateFn.self)
    private static let setLevel = fn(["SLSSpaceSetAbsoluteLevel", "CGSSpaceSetAbsoluteLevel"], LevelFn.self)
    private static let addWindows = fn(["SLSAddWindowsToSpaces", "CGSAddWindowsToSpaces"], WindowsFn.self)
    private static let removeWindows = fn(["SLSRemoveWindowsFromSpaces", "CGSRemoveWindowsFromSpaces"], WindowsFn.self)
    private static let show = fn(["SLSShowSpaces", "CGSShowSpaces"], SpacesFn.self)

    private var space: UInt64 = 0
    private var members = Set<Int>()

    private init() {}

    private func ensureSpace() -> Bool {
        if space != 0 { return true }
        guard let conn = Self.connection, let create = Self.create, let setLevel = Self.setLevel,
              let show = Self.show else { return false }
        let cid = conn()
        // Flag 1 makes a plain overlay space (other values make Finder draw desktop icons into it).
        let id = create(cid, 1, nil)
        guard id != 0 else { return false }
        _ = setLevel(cid, id, Int32.max)
        _ = show(cid, [NSNumber(value: id)] as CFArray)
        space = id
        return true
    }

    func add(_ window: NSWindow) {
        let number = window.windowNumber
        guard number > 0, !members.contains(number), ensureSpace(),
              let conn = Self.connection, let add = Self.addWindows else { return }
        _ = add(conn(), [NSNumber(value: number)] as CFArray, [NSNumber(value: space)] as CFArray)
        members.insert(number)
    }

    func remove(_ window: NSWindow) {
        let number = window.windowNumber
        guard members.contains(number), let conn = Self.connection, let remove = Self.removeWindows else { return }
        _ = remove(conn(), [NSNumber(value: number)] as CFArray, [NSNumber(value: space)] as CFArray)
        members.remove(number)
    }
}
