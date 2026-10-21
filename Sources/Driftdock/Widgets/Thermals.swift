import Foundation
import IOKit

/// Reads the chip's temperature sensors on Apple Silicon through IOKit's HID event
/// system (the same sensors tools like Stats read). It isn't public API, so every
/// function is looked up at runtime; if anything is missing we return nil and the
/// widget falls back to macOS's thermal state.
enum Thermals {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    private typealias SetMatchingFn = @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Int32
    private typealias CopyServicesFn = @convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFArray>?
    private typealias CopyEventFn = @convention(c) (UnsafeRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    private typealias GetFloatFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Double
    private typealias CopyPropertyFn = @convention(c) (UnsafeRawPointer, CFString) -> Unmanaged<CFTypeRef>?

    private static let lib = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    private static func fn<T>(_ name: String, _ type: T.Type) -> T? {
        guard let lib, let sym = dlsym(lib, name) else { return nil }
        return unsafeBitCast(sym, to: type)
    }

    private static let create = fn("IOHIDEventSystemClientCreate", CreateFn.self)
    private static let setMatching = fn("IOHIDEventSystemClientSetMatching", SetMatchingFn.self)
    private static let copyServices = fn("IOHIDEventSystemClientCopyServices", CopyServicesFn.self)
    private static let copyEvent = fn("IOHIDServiceClientCopyEvent", CopyEventFn.self)
    private static let getFloat = fn("IOHIDEventGetFloatValue", GetFloatFn.self)
    private static let copyProperty = fn("IOHIDServiceClientCopyProperty", CopyPropertyFn.self)

    private static let temperatureType: Int64 = 15            // kIOHIDEventTypeTemperature
    private static let temperatureField = Int32(15 << 16)      // its level field

    /// One long-lived client watching only temperature sensors.
    private static let client: UnsafeMutableRawPointer? = {
        guard let createFn = Thermals.create, let matchFn = Thermals.setMatching,
              let client = createFn(kCFAllocatorDefault) else { return nil }
        let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
        _ = matchFn(client, matching)
        return client
    }()

    /// Average die temperature in °C, or nil if this Mac doesn't expose it.
    static func cpuCelsius() -> Double? {
        guard let client = Thermals.client,
              let copyServicesFn = Thermals.copyServices,
              let copyEventFn = Thermals.copyEvent,
              let getFloatFn = Thermals.getFloat,
              let copyPropertyFn = Thermals.copyProperty,
              let services = copyServicesFn(client)?.takeRetainedValue() else { return nil }

        var dies: [Double] = []
        var others: [Double] = []
        for i in 0..<CFArrayGetCount(services) {
            guard let service = CFArrayGetValueAtIndex(services, i) else { continue }
            let name = (copyPropertyFn(service, "Product" as CFString)?.takeRetainedValue() as? String) ?? ""
            guard let event = copyEventFn(service, Thermals.temperatureType, 0, 0) else { continue }
            let value = getFloatFn(event, Thermals.temperatureField)
            Unmanaged<CFTypeRef>.fromOpaque(event).release()
            guard value > 5, value < 130 else { continue }   // ignore unplugged/garbage sensors
            let n = name.lowercased()
            if n.contains("tdie") || n.contains("tdev") || n.contains("cpu") || n.contains("soc") {
                dies.append(value)
            } else if n.hasPrefix("pmu") {
                others.append(value)
            }
        }
        let pool = dies.isEmpty ? others : dies
        guard !pool.isEmpty else { return nil }
        return pool.reduce(0, +) / Double(pool.count)
    }
}
