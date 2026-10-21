import SwiftUI
import AppKit
import IOBluetooth

/// Battery levels for connected Bluetooth accessories (AirPods left/right/case, keyboards, mice…).
/// Reads what macOS itself reports through `system_profiler`, so no private APIs.
final class DevicesModel: NSObject, ObservableObject {
    static let shared = DevicesModel()

    struct Device: Identifiable, Equatable {
        let name: String
        let minorType: String
        let left: Int?
        let right: Int?
        let caseLevel: Int?
        let main: Int?
        var id: String { name }

        var isEarbuds: Bool { left != nil || right != nil }

        /// The lowest bud (or the single battery) for compact displays.
        var summary: Int? {
            let buds = [left, right].compactMap { $0 }
            return buds.min() ?? main
        }

        var symbol: String {
            let n = name.lowercased()
            if isEarbuds || n.contains("airpods") {
                if n.contains("max") { return "airpodsmax" }
                if n.contains("pro") { return "airpodspro" }
                return "airpods"
            }
            let t = minorType.lowercased()
            if t.contains("headphone") || t.contains("headset") { return "headphones" }
            if t.contains("keyboard") { return "keyboard" }
            if t.contains("mouse") { return "computermouse" }
            if t.contains("trackpad") { return "hand.point.up.left" }
            if t.contains("gamepad") || t.contains("controller") { return "gamecontroller" }
            return "dot.radiowaves.left.and.right"
        }
    }

    @Published private(set) var devices: [Device] = []

    private var timer: Timer?
    private var reading = false
    private var known = Set<String>()
    private var firstRead = true
    private var connectNote: IOBluetoothUserNotification?

    private override init() { super.init() }

    func start() {
        guard timer == nil else { return }
        refresh()
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // Refresh soon after anything connects (batteries report a few seconds later).
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        connectNote?.unregister()
        connectNote = nil
        devices = []
    }

    @objc private func deviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        for delay in [3.0, 8.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refresh() }
        }
    }

    func refresh() {
        guard !reading else { return }
        reading = true
        DispatchQueue.global(qos: .utility).async {
            let list = Self.read()
            DispatchQueue.main.async {
                self.reading = false
                let names = Set(list.map(\.name))
                if !self.firstRead, let fresh = list.first(where: { !self.known.contains($0.name) }) {
                    LiveActivityCenter.shared.showDevice(.init(name: fresh.name, symbol: fresh.symbol, level: fresh.summary,
                                                               left: fresh.left, right: fresh.right, caseLevel: fresh.caseLevel))
                }
                self.firstRead = false
                self.known = names
                if list != self.devices { self.devices = list }
            }
        }
    }

    private static func read() -> [Device] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var result: [Device] = []
        for section in sections {
            guard let connected = section["device_connected"] as? [[String: Any]] else { continue }
            for entry in connected {
                for (name, value) in entry {
                    guard let props = value as? [String: Any] else { continue }
                    func level(_ key: String) -> Int? {
                        guard let s = props[key] as? String else { return nil }
                        return Int(s.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
                    }
                    let d = Device(name: name,
                                   minorType: props["device_minorType"] as? String ?? "",
                                   left: level("device_batteryLevelLeft"),
                                   right: level("device_batteryLevelRight"),
                                   caseLevel: level("device_batteryLevelCase"),
                                   main: level("device_batteryLevelMain") ?? level("device_batteryLevel"))
                    if d.left != nil || d.right != nil || d.caseLevel != nil || d.main != nil {
                        result.append(d)
                    }
                }
            }
        }
        // Earbuds first, then by name.
        return result.sorted { ($0.isEarbuds ? 0 : 1, $0.name) < ($1.isEarbuds ? 0 : 1, $1.name) }
    }
}

// MARK: - Views

/// One device: icon plus L / R / Case (or a single level).
struct DeviceBatteryRow: View {
    let device: DevicesModel.Device
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 6 : 10) {
            Image(systemName: device.symbol)
                .font(.system(size: compact ? 14 : 18))
                .frame(width: compact ? 18 : 24)
            if !compact {
                Text(device.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
            }
            if device.isEarbuds {
                level("L", device.left)
                level("R", device.right)
                if let c = device.caseLevel { level("Case", c) }
            } else if let m = device.main {
                level("", m)
            }
        }
    }

    @ViewBuilder
    private func level(_ label: String, _ value: Int?) -> some View {
        if let value {
            HStack(spacing: 2) {
                if !label.isEmpty {
                    Text(label).font(.system(size: compact ? 9 : 10, weight: .bold)).foregroundStyle(.secondary)
                }
                Text("\(value)%")
                    .font(.system(size: compact ? 11 : 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(value <= 20 ? Color.red : Color.primary)
            }
        }
    }
}

/// Dock widget; only takes room while a device with a battery is connected.
struct DevicesWidget: View {
    @ObservedObject var model = DevicesModel.shared
    @Environment(\.dockUnit) var u

    var body: some View {
        let list = Array(model.devices.prefix(2))
        Tile(span: list.isEmpty ? 1.6 : (list.count == 1 ? 2.6 : 3.0)) {
            VStack(alignment: .leading, spacing: u * 0.06) {
                if list.isEmpty {
                    Label("No devices", systemImage: "airpods").font(.system(size: u * 0.13)).foregroundStyle(.secondary)
                }
                ForEach(list) { d in
                    DeviceBatteryRow(device: d, compact: true)
                }
            }
            .padding(.horizontal, u * 0.16)
        }
        .help(model.devices.map { $0.name }.joined(separator: ", "))
        .onAppear { model.start() }
    }
}
