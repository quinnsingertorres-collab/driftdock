import SwiftUI
import Darwin
import IOKit.ps

final class StatsModel: ObservableObject {
    static let shared = StatsModel()

    @Published var cpu: Double = 0
    @Published var memory: Double = 0
    @Published var battery: Double?
    @Published var charging = false
    /// Chip temperature in °C when the sensors can be read.
    @Published var temperature: Double?
    /// macOS's own coarse reading, used when there's no sensor value.
    @Published var thermalState: ProcessInfo.ThermalState = .nominal

    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var timer: Timer?

    private init() {
        sample()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.sample() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func sample() {
        if let ticks = Self.cpuTicks() {
            if let last = lastTicks, ticks.total > last.total, ticks.busy >= last.busy {
                cpu = Double(ticks.busy - last.busy) / Double(ticks.total - last.total)
            }
            lastTicks = ticks
        }
        memory = Self.memoryUsage()
        let temp = Thermals.cpuCelsius()
        if temp.map({ Int($0) }) != temperature.map({ Int($0) }) { temperature = temp }
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal != thermalState { thermalState = thermal }
        let (level, isCharging) = Self.batteryLevel()
        if let level, let previous = battery, previous < 0.995, level >= 0.995, charging || isCharging {
            LiveActivityCenter.shared.showBanner(.init(symbol: "battery.100percent.bolt", tint: .green,
                                                       title: "Full Battery", value: "100%",
                                                       subtitle: "Your Mac is fully charged."))
        }
        if battery != level { battery = level }
        if charging != isCharging { charging = isCharging }
    }

    private static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        let busy = user + system + nice
        return (busy, busy + idle)
    }

    /// Roughly Activity Monitor's "Memory Used": app memory + wired + compressed.
    private static func memoryUsage() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let page = UInt64(getpagesize())
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let appPages = internalPages > purgeable ? internalPages - purgeable : 0
        let used = (appPages + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        let total = ProcessInfo.processInfo.physicalMemory
        return total > 0 ? min(1, Double(used) / Double(total)) : 0
    }

    private static func batteryLevel() -> (Double?, Bool) {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return (nil, false)
        }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
            return (Double(current) / Double(max), charging)
        }
        return (nil, false)
    }
}

struct StatsWidget: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var model = StatsModel.shared
    @Environment(\.dockUnit) var u

    var body: some View {
        let hasBattery = model.battery != nil
        let showTemp = state.config.statsShowTemp
        Tile(span: (hasBattery ? 2.3 : 1.6) + (showTemp ? 0.68 : 0)) {
            HStack(spacing: u * 0.14) {
                Ring(value: model.cpu, label: "CPU", tint: tint(model.cpu))
                Ring(value: model.memory, label: "MEM", tint: tint(model.memory))
                if let b = model.battery {
                    Ring(value: b, label: model.charging ? "⚡︎BAT" : "BAT",
                         tint: b < 0.2 ? .red : .green)
                }
                if showTemp { temperatureRing }
            }
        }
        .onTapGesture {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
                                               configuration: NSWorkspace.OpenConfiguration())
        }
        .help("Click to open Activity Monitor")
        .contextMenu {
            Toggle("Show Temperature", isOn: $state.config.statsShowTemp)
            Button("Remove System Stats") {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { state.setWidget(.stats, enabled: false) }
            }
        }
    }

    /// Real temperature when available, otherwise macOS's Cool / Warm / Hot.
    @ViewBuilder
    private var temperatureRing: some View {
        if let c = model.temperature {
            Ring(value: min(1, max(0, (c - 25) / 80)), label: "TEMP",
                 tint: tempColor(c), text: tempText(c))
        } else {
            let info = thermalInfo(model.thermalState)
            Ring(value: info.fraction, label: "HEAT", tint: info.color, text: info.word)
        }
    }

    private func tempText(_ celsius: Double) -> String {
        let shown = state.config.fahrenheit ? celsius * 9 / 5 + 32 : celsius
        return "\(Int(shown.rounded()))°"
    }

    private func tempColor(_ celsius: Double) -> Color {
        if celsius >= 90 { return .red }
        if celsius >= 75 { return .orange }
        return .green
    }

    private struct ThermalInfo {
        let fraction: Double
        let word: String
        let color: Color
    }

    private func thermalInfo(_ s: ProcessInfo.ThermalState) -> ThermalInfo {
        switch s {
        case .nominal: return ThermalInfo(fraction: 0.25, word: "Cool", color: .green)
        case .fair: return ThermalInfo(fraction: 0.5, word: "Warm", color: .yellow)
        case .serious: return ThermalInfo(fraction: 0.75, word: "Hot", color: .orange)
        case .critical: return ThermalInfo(fraction: 1, word: "Hot!", color: .red)
        @unknown default: return ThermalInfo(fraction: 0.25, word: "OK", color: .green)
        }
    }

    private func tint(_ v: Double) -> Color {
        v > 0.85 ? .red : (v > 0.6 ? .orange : state.accent)
    }
}

struct Ring: View {
    @Environment(\.dockUnit) var u
    let value: Double
    let label: String
    let tint: Color
    /// What to show inside the ring; defaults to the percentage.
    var text: String? = nil

    private var textScale: CGFloat {
        guard let text else { return 0.13 }
        return text.count > 3 ? 0.1 : 0.12
    }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.12), lineWidth: u * 0.055)
                Circle()
                    .trim(from: 0, to: max(0.001, min(1, value)))
                    .stroke(tint, style: StrokeStyle(lineWidth: u * 0.055, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.6), value: value)
                Text(text ?? "\(Int((value * 100).rounded()))")
                    .font(.system(size: u * textScale, weight: .semibold, design: .rounded))
                    .minimumScaleFactor(0.7)
                    .monospacedDigit()
            }
            .frame(width: u * 0.44, height: u * 0.44)
            Text(label)
                .font(.system(size: u * 0.1, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }
}
