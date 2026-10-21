import Foundation
import Network
import CoreGraphics

// Glide: share one mouse and keyboard between this Mac and a Windows PC (or another Mac).
// Wire protocol — must match glide/windows/Protocol.cs and glide/mac/Protocol.swift exactly.
//
// Every message is 25 bytes, little-endian: type (1), i1 (Int32), i2 (Int32), d1 (Double), d2 (Double).
// Keys travel as USB HID usage IDs so neither side needs to know the other's keyboard codes.

enum GlideWire {
    static let serviceType = "_glide._tcp"
    static let port: NWEndpoint.Port = 24811
    static let platformMac: Int32 = 0
    static let platformWindows: Int32 = 1

    /// TCP with Nagle off, so tiny mouse packets go out immediately.
    static func params() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let p = NWParameters(tls: nil, tcp: tcp)
        p.allowLocalEndpointReuse = true
        return p
    }

    /// Reads fixed-size messages until the connection closes, then calls onClose once.
    static func receiveLoop(_ conn: NWConnection, onClose: @escaping () -> Void, _ handle: @escaping (GlideMsg) -> Void) {
        conn.receive(minimumIncompleteLength: GlideMsg.size, maximumLength: GlideMsg.size) { data, _, isComplete, error in
            if let data, let msg = GlideMsg(data) { handle(msg) }
            if error == nil && !isComplete {
                receiveLoop(conn, onClose: onClose, handle)
            } else {
                onClose()
            }
        }
    }

    /// This Mac's IPv4 addresses on Wi-Fi / Ethernet, so you know what to type on the PC.
    static func localIPv4() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return result }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            guard String(cString: ifa.ifa_name).hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(cString: host))
            }
        }
        return result
    }
}

enum GlideMsgType: UInt8 {
    case hello = 1   // receiver -> sharer   d1 = width, d2 = height, i1 = platform
    case enter = 2   // sharer -> receiver   d1 = x, d2 = y
    case move = 3    //                      d1 = x, d2 = y, i1 = dx, i2 = dy
    case button = 4  //                      i1 = 0 left, 1 right, 2 middle, 3 back, 4 forward; i2 = 1 down / 0 up
    case scroll = 5  //                      d1 = vertical, d2 = horizontal, pixels; positive = up / right
    case key = 6     //                      i1 = HID usage ID, i2 = 1 down / 0 up
    case leave = 8   // cursor went back to the sharer
}

struct GlideMsg {
    var type: GlideMsgType
    var i1: Int32 = 0
    var i2: Int32 = 0
    var d1: Double = 0
    var d2: Double = 0

    static let size = 25

    func encode() -> Data {
        var data = Data(capacity: GlideMsg.size)
        data.append(type.rawValue)
        withUnsafeBytes(of: i1.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: i2.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: d1.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: d2.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        return data
    }

    init(type: GlideMsgType, i1: Int32 = 0, i2: Int32 = 0, d1: Double = 0, d2: Double = 0) {
        self.type = type; self.i1 = i1; self.i2 = i2; self.d1 = d1; self.d2 = d2
    }

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count == GlideMsg.size, let t = GlideMsgType(rawValue: bytes[0]) else { return nil }
        func read<T: FixedWidthInteger>(_ offset: Int, _: T.Type) -> T {
            var v: T = 0
            for i in 0..<MemoryLayout<T>.size { v |= T(bytes[offset + i]) << (8 * i) }
            return v
        }
        self.init(type: t,
                  i1: Int32(bitPattern: read(1, UInt32.self)),
                  i2: Int32(bitPattern: read(5, UInt32.self)),
                  d1: Double(bitPattern: read(9, UInt64.self)),
                  d2: Double(bitPattern: read(17, UInt64.self)))
    }
}

// MARK: - Key tables

enum GlideKeys {
    /// USB HID usage ID -> macOS virtual keycode (kVK_*).
    static let hidToMac: [UInt16: UInt16] = [
        // Letters
        0x04: 0x00, 0x05: 0x0B, 0x06: 0x08, 0x07: 0x02, 0x08: 0x0E, 0x09: 0x03, 0x0A: 0x05, 0x0B: 0x04,
        0x0C: 0x22, 0x0D: 0x26, 0x0E: 0x28, 0x0F: 0x25, 0x10: 0x2E, 0x11: 0x2D, 0x12: 0x1F, 0x13: 0x23,
        0x14: 0x0C, 0x15: 0x0F, 0x16: 0x01, 0x17: 0x11, 0x18: 0x20, 0x19: 0x09, 0x1A: 0x0D, 0x1B: 0x07,
        0x1C: 0x10, 0x1D: 0x06,
        // Number row 1-9, 0
        0x1E: 0x12, 0x1F: 0x13, 0x20: 0x14, 0x21: 0x15, 0x22: 0x17, 0x23: 0x16, 0x24: 0x1A, 0x25: 0x1C,
        0x26: 0x19, 0x27: 0x1D,
        // Enter, Esc, Backspace, Tab, Space, - = [ ] \ ; ' ` , . /  CapsLock
        0x28: 0x24, 0x29: 0x35, 0x2A: 0x33, 0x2B: 0x30, 0x2C: 0x31, 0x2D: 0x1B, 0x2E: 0x18, 0x2F: 0x21,
        0x30: 0x1E, 0x31: 0x2A, 0x33: 0x29, 0x34: 0x27, 0x35: 0x32, 0x36: 0x2B, 0x37: 0x2F, 0x38: 0x2C,
        0x39: 0x39,
        // F1-F12
        0x3A: 0x7A, 0x3B: 0x78, 0x3C: 0x63, 0x3D: 0x76, 0x3E: 0x60, 0x3F: 0x61, 0x40: 0x62, 0x41: 0x64,
        0x42: 0x65, 0x43: 0x6D, 0x44: 0x67, 0x45: 0x6F,
        // Insert(=Help), Home, PageUp, Delete, End, PageDown, Right, Left, Down, Up
        0x49: 0x72, 0x4A: 0x73, 0x4B: 0x74, 0x4C: 0x75, 0x4D: 0x77, 0x4E: 0x79, 0x4F: 0x7C, 0x50: 0x7B,
        0x51: 0x7D, 0x52: 0x7E,
        // Keypad: NumLock(=Clear) / * - + Enter 1-9 0 . =
        0x53: 0x47, 0x54: 0x4B, 0x55: 0x43, 0x56: 0x4E, 0x57: 0x45, 0x58: 0x4C, 0x59: 0x53, 0x5A: 0x54,
        0x5B: 0x55, 0x5C: 0x56, 0x5D: 0x57, 0x5E: 0x58, 0x5F: 0x59, 0x60: 0x5B, 0x61: 0x5C, 0x62: 0x52,
        0x63: 0x41, 0x67: 0x51,
        // ISO key, F13-F15 (PrintScreen/ScrollLock/Pause on PC keyboards land on F13-F15)
        0x64: 0x0A, 0x68: 0x69, 0x69: 0x6B, 0x6A: 0x71, 0x46: 0x69, 0x47: 0x6B, 0x48: 0x71,
        // Modifiers: LCtrl LShift LAlt LCmd RCtrl RShift RAlt RCmd
        0xE0: 0x3B, 0xE1: 0x38, 0xE2: 0x3A, 0xE3: 0x37, 0xE4: 0x3E, 0xE5: 0x3C, 0xE6: 0x3D, 0xE7: 0x36,
    ]

    static let macToHid: [UInt16: UInt16] = {
        var out: [UInt16: UInt16] = [:]
        for (hid, mac) in hidToMac where ![0x46, 0x47, 0x48].contains(hid) { out[mac] = hid }
        return out
    }()

    /// Modifier HID usages and the CGEventFlags they turn on (general mask + left/right device bit).
    static let modifierFlags: [UInt16: CGEventFlags] = [
        0xE0: [.maskControl, CGEventFlags(rawValue: 0x0001)],
        0xE1: [.maskShift, CGEventFlags(rawValue: 0x0002)],
        0xE2: [.maskAlternate, CGEventFlags(rawValue: 0x0020)],
        0xE3: [.maskCommand, CGEventFlags(rawValue: 0x0008)],
        0xE4: [.maskControl, CGEventFlags(rawValue: 0x2000)],
        0xE5: [.maskShift, CGEventFlags(rawValue: 0x0004)],
        0xE6: [.maskAlternate, CGEventFlags(rawValue: 0x0040)],
        0xE7: [.maskCommand, CGEventFlags(rawValue: 0x0010)],
    ]

    /// Mac modifier keycode -> (device bit set while held, HID usage).
    static let macModifierKeys: [UInt16: (bit: UInt64, hid: UInt16)] = [
        0x3B: (0x0001, 0xE0), 0x38: (0x0002, 0xE1), 0x3A: (0x0020, 0xE2), 0x37: (0x0008, 0xE3),
        0x3E: (0x2000, 0xE4), 0x3C: (0x0004, 0xE5), 0x3D: (0x0040, 0xE6), 0x36: (0x0010, 0xE7),
    ]
}
