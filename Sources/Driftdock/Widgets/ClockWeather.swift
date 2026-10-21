import SwiftUI
import AppKit
import CoreLocation

// MARK: - Clock

/// Clock options that can be shared by the dock widget and the notch.
enum ClockFormat {
    static func design(_ name: String) -> Font.Design {
        switch name {
        case "serif": return .serif
        case "mono": return .monospaced
        case "default": return .default
        default: return .rounded
        }
    }

    static func weight(_ name: String) -> Font.Weight {
        switch name {
        case "light": return .light
        case "regular": return .regular
        case "bold": return .bold
        case "heavy": return .heavy
        default: return .semibold
        }
    }

    static func time(_ date: Date, cfg: Config, zone: TimeZone = .current, ampm: Bool = true) -> String {
        let f = DateFormatter()
        f.timeZone = zone
        f.locale = Locale.current
        let base = cfg.clock24h ? "HH:mm" : "h:mm"
        let secs = cfg.clockSeconds ? ":ss" : ""
        f.dateFormat = base + secs + (!cfg.clock24h && ampm ? " a" : "")
        return f.string(from: date)
    }

    static func date(_ date: Date, cfg: Config) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        switch cfg.clockDateStyle {
        case "numeric": f.setLocalizedDateFormatFromTemplate("Mdyy")
        case "full": f.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        case "day": f.setLocalizedDateFormatFromTemplate("EEEE")
        default: f.setLocalizedDateFormatFromTemplate("EEEMMMd")
        }
        return f.string(from: date)
    }

    struct WorldZone: Hashable {
        let id: String
        let label: String
    }

    /// Color choices for the clock face/text.
    struct ClockColor: Hashable {
        let id: String
        let name: String
    }

    static let colors: [ClockColor] = [
        ClockColor(id: "default", name: "White"), ClockColor(id: "accent", name: "Accent"),
        ClockColor(id: "red", name: "Red"), ClockColor(id: "orange", name: "Orange"),
        ClockColor(id: "yellow", name: "Yellow"), ClockColor(id: "green", name: "Green"),
        ClockColor(id: "mint", name: "Mint"), ClockColor(id: "blue", name: "Blue"),
        ClockColor(id: "purple", name: "Purple"), ClockColor(id: "pink", name: "Pink"),
    ]

    static func color(_ id: String, accent: Color) -> Color {
        switch id {
        case "accent": return accent
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "mint": return .mint
        case "blue": return .blue
        case "purple": return .purple
        case "pink": return .pink
        default: return .primary
        }
    }

    /// One-click looks shown when you click the clock.
    struct Preset: Identifiable {
        let id: String
        let name: String
        let style: String
        let font: String
        let weight: String
    }

    static let presets: [Preset] = [
        Preset(id: "classic", name: "Classic", style: "digital", font: "rounded", weight: "semibold"),
        Preset(id: "bold", name: "Bold", style: "digital", font: "rounded", weight: "heavy"),
        Preset(id: "thin", name: "Thin", style: "digital", font: "default", weight: "light"),
        Preset(id: "serif", name: "Serif", style: "digital", font: "serif", weight: "regular"),
        Preset(id: "mono", name: "Mono", style: "digital", font: "mono", weight: "regular"),
        Preset(id: "analog", name: "Analog", style: "analog", font: "rounded", weight: "semibold"),
        Preset(id: "both", name: "Both", style: "both", font: "rounded", weight: "semibold"),
    ]

    /// A handful of world clocks to choose from.
    static let zones: [WorldZone] = [
        WorldZone(id: "America/Los_Angeles", label: "Los Angeles"),
        WorldZone(id: "America/Denver", label: "Denver"),
        WorldZone(id: "America/Chicago", label: "Chicago"),
        WorldZone(id: "America/New_York", label: "New York"),
        WorldZone(id: "America/Sao_Paulo", label: "São Paulo"),
        WorldZone(id: "Europe/London", label: "London"),
        WorldZone(id: "Europe/Paris", label: "Paris"),
        WorldZone(id: "Europe/Berlin", label: "Berlin"),
        WorldZone(id: "Africa/Cairo", label: "Cairo"),
        WorldZone(id: "Asia/Dubai", label: "Dubai"),
        WorldZone(id: "Asia/Kolkata", label: "Mumbai"),
        WorldZone(id: "Asia/Singapore", label: "Singapore"),
        WorldZone(id: "Asia/Shanghai", label: "Shanghai"),
        WorldZone(id: "Asia/Tokyo", label: "Tokyo"),
        WorldZone(id: "Asia/Seoul", label: "Seoul"),
        WorldZone(id: "Australia/Sydney", label: "Sydney"),
        WorldZone(id: "Pacific/Auckland", label: "Auckland"),
        WorldZone(id: "Pacific/Honolulu", label: "Honolulu"),
        WorldZone(id: "UTC", label: "UTC"),
    ]

    static func label(for zoneID: String) -> String {
        zones.first { $0.id == zoneID }?.label ?? zoneID
    }
}

struct ClockWidget: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dockUnit) var u
    @Environment(\.dockEdge) var edge
    @State private var showOptions = false

    var body: some View {
        let cfg = state.config
        let zone = cfg.clockSecondZone.isEmpty ? nil : TimeZone(identifier: cfg.clockSecondZone)
        let analog = cfg.clockStyle == "analog"
        let both = cfg.clockStyle == "both"
        let digitalSpan: CGFloat = (cfg.clockSeconds ? 2.2 : 1.7) + (cfg.clock24h ? -0.2 : 0)
        let span = analog ? 1 : digitalSpan + (both ? 0.9 : 0) + (zone != nil ? 1.5 : 0)

        Tile(span: span) {
            // Tick every second only when something shows seconds.
            TimelineView(.periodic(from: .now, by: (cfg.clockSeconds || analog || both) ? 1 : 15)) { ctx in
                HStack(spacing: u * 0.12) {
                    if analog || both {
                        AnalogClock(date: ctx.date, showSeconds: cfg.clockSeconds || analog,
                                    accent: cfg.clockAccentSeconds ? state.accent : Color.primary,
                                    tint: ClockFormat.color(cfg.clockColor, accent: state.accent))
                            .frame(width: u * 0.74, height: u * 0.74)
                    }
                    if !analog {
                        digital(ctx.date, cfg: cfg)
                    }
                    if let zone, !analog {
                        Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1, height: u * 0.5)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ClockFormat.time(ctx.date, cfg: cfg, zone: zone))
                                .font(.system(size: u * 0.2, weight: ClockFormat.weight(cfg.clockWeight),
                                              design: ClockFormat.design(cfg.clockFont)))
                                .monospacedDigit()
                            Text(ClockFormat.label(for: cfg.clockSecondZone) + dayShift(ctx.date, zone))
                                .font(.system(size: u * 0.12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, u * 0.12)
            }
        }
        .onTapGesture { showOptions.toggle() }
        .help("Click for clock styles and colors")
        .popover(isPresented: $showOptions, arrowEdge: edge.popoverArrow) {
            ClockOptionsPopover()
                .environmentObject(state)
                .borrowsFocus()
        }
    }

    static func openClockApp() {
        if let clock = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.clock") {
            NSWorkspace.shared.openApplication(at: clock, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func digital(_ date: Date, cfg: Config) -> some View {
        VStack(spacing: 1) {
            Text(ClockFormat.time(date, cfg: cfg))
                .font(.system(size: u * 0.3, weight: ClockFormat.weight(cfg.clockWeight),
                              design: ClockFormat.design(cfg.clockFont)))
                .monospacedDigit()
                .foregroundStyle(ClockFormat.color(cfg.clockColor, accent: state.accent))
            if cfg.clockShowDate {
                Text(ClockFormat.date(date, cfg: cfg))
                    .font(.system(size: u * 0.14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// " +1" / " −1" when the other city is on a different day.
    private func dayShift(_ date: Date, _ zone: TimeZone) -> String {
        var here = Calendar.current
        here.timeZone = .current
        var there = Calendar.current
        there.timeZone = zone
        let a = here.component(.day, from: date)
        let b = there.component(.day, from: date)
        if a == b { return "" }
        let ahead = zone.secondsFromGMT(for: date) > TimeZone.current.secondsFromGMT(for: date)
        return ahead ? " · Tomorrow" : " · Yesterday"
    }
}

/// What opens when you click the clock: looks, colors and quick options.
struct ClockOptionsPopover: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let cfg = state.config
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Clock").font(.headline)
                Spacer()
                Button("Open Clock App") { ClockWidget.openClockApp() }
                    .controlSize(.small)
            }

            Text("Style").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(ClockFormat.presets) { p in
                    let selected = cfg.clockStyle == p.style && (p.style != "digital" || (cfg.clockFont == p.font && cfg.clockWeight == p.weight))
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            state.config.clockStyle = p.style
                            state.config.clockFont = p.font
                            state.config.clockWeight = p.weight
                        }
                    } label: {
                        VStack(spacing: 4) {
                            presetPreview(p)
                                .frame(height: 34)
                            Text(p.name).font(.system(size: 10, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(selected ? state.accent.opacity(0.3) : Color.primary.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(selected ? state.accent : Color.clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("Color").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(ClockFormat.colors, id: \.id) { c in
                    Button {
                        state.config.clockColor = c.id
                    } label: {
                        Circle()
                            .fill(c.id == "default" ? Color.white : ClockFormat.color(c.id, accent: state.accent))
                            .frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.25)))
                            .overlay(Circle().strokeBorder(Color.primary, lineWidth: cfg.clockColor == c.id ? 2 : 0).padding(-3))
                    }
                    .buttonStyle(.plain)
                    .help(c.name)
                }
            }

            Divider()
            HStack(spacing: 14) {
                Toggle("24-hour", isOn: $state.config.clock24h)
                Toggle("Seconds", isOn: $state.config.clockSeconds)
                Toggle("Date", isOn: $state.config.clockShowDate)
            }
            .toggleStyle(.checkbox)
            Picker("World clock", selection: $state.config.clockSecondZone) {
                Text("None").tag("")
                ForEach(ClockFormat.zones, id: \.id) { z in Text(z.label).tag(z.id) }
            }
            Button("More options in Settings…") {
                NotificationCenter.default.post(name: .driftdockOpenSettings, object: nil)
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(14)
        .frame(width: 360)
    }

    @ViewBuilder
    private func presetPreview(_ p: ClockFormat.Preset) -> some View {
        let tint = ClockFormat.color(state.config.clockColor, accent: state.accent)
        switch p.style {
        case "analog":
            AnalogClock(date: Date(), showSeconds: false, accent: state.accent, tint: tint).frame(width: 30, height: 30)
        case "both":
            HStack(spacing: 3) {
                AnalogClock(date: Date(), showSeconds: false, accent: state.accent, tint: tint).frame(width: 22, height: 22)
                Text("9:41").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(tint)
            }
        default:
            Text("9:41")
                .font(.system(size: 18, weight: ClockFormat.weight(p.weight), design: ClockFormat.design(p.font)))
                .foregroundStyle(tint)
        }
    }
}

/// A small analog clock face.
struct AnalogClock: View {
    let date: Date
    let showSeconds: Bool
    let accent: Color
    var tint: Color = .primary

    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width, size.height) / 2
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                     with: .color(.primary.opacity(0.08)))
            for i in 0..<12 {
                let a = Double(i) / 12 * 2 * .pi
                let long = i % 3 == 0
                let p1 = point(c, r * (long ? 0.74 : 0.82), a)
                let p2 = point(c, r * 0.92, a)
                var tick = Path(); tick.move(to: p1); tick.addLine(to: p2)
                ctx.stroke(tick, with: .color(.primary.opacity(long ? 0.7 : 0.35)), lineWidth: long ? 1.6 : 1)
            }
            let comps = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
            let sec = Double(comps.second ?? 0)
            let min = Double(comps.minute ?? 0) + sec / 60
            let hr = Double((comps.hour ?? 0) % 12) + min / 60
            hand(ctx, c, r * 0.5, hr / 12, tint, 3)
            hand(ctx, c, r * 0.74, min / 60, tint, 2)
            if showSeconds { hand(ctx, c, r * 0.82, sec / 60, accent, 1) }
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5)), with: .color(accent))
        }
    }

    private func point(_ c: CGPoint, _ len: CGFloat, _ angle: Double) -> CGPoint {
        CGPoint(x: c.x + len * CGFloat(sin(angle)), y: c.y - len * CGFloat(cos(angle)))
    }

    private func hand(_ ctx: GraphicsContext, _ c: CGPoint, _ len: CGFloat, _ fraction: Double, _ color: Color, _ width: CGFloat) {
        var p = Path()
        p.move(to: c)
        p.addLine(to: point(c, len, fraction * 2 * .pi))
        ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
    }
}

// MARK: - Weather (Open-Meteo, no API key)

final class WeatherModel: ObservableObject {
    static let shared = WeatherModel()

    struct Day: Identifiable {
        let id: String
        let label: String
        let symbol: String
        let high: Double
        let low: Double
    }

    struct Snapshot {
        let temp: Double
        let symbol: String
        let days: [Day]
    }

    @Published var snapshot: Snapshot?
    @Published var failed = false

    private struct Response: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let weather_code: Int
        }
        struct Daily: Decodable {
            let time: [String]
            let weather_code: [Int]
            let temperature_2m_max: [Double]
            let temperature_2m_min: [Double]
        }
        let current: Current
        let daily: Daily
    }

    func load(latitude: Double, longitude: Double, fahrenheit: Bool) async {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "4"),
        ]
        guard let url = comps.url else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let r = try JSONDecoder().decode(Response.self, from: data)

            let parser = DateFormatter()
            parser.dateFormat = "yyyy-MM-dd"
            let weekday = DateFormatter()
            weekday.dateFormat = "EEE"

            var days: [Day] = []
            let n = min(r.daily.time.count, r.daily.weather_code.count,
                        r.daily.temperature_2m_max.count, r.daily.temperature_2m_min.count)
            for i in 0..<n where i > 0 { // skip today; the big number already covers it
                let date = parser.date(from: r.daily.time[i])
                days.append(Day(id: r.daily.time[i],
                                label: date.map { weekday.string(from: $0) } ?? "",
                                symbol: Self.symbol(for: r.daily.weather_code[i]),
                                high: r.daily.temperature_2m_max[i],
                                low: r.daily.temperature_2m_min[i]))
            }
            let snap = Snapshot(temp: r.current.temperature_2m,
                                symbol: Self.symbol(for: r.current.weather_code),
                                days: days)
            await MainActor.run {
                self.snapshot = snap
                self.failed = false
            }
        } catch {
            await MainActor.run {
                if self.snapshot == nil { self.failed = true }
            }
        }
    }

    /// WMO weather codes → SF Symbols.
    static func symbol(for code: Int) -> String {
        switch code {
        case 0: return "sun.max.fill"
        case 1, 2: return "cloud.sun.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...67: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 80...82: return "cloud.heavyrain.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }
}

struct WeatherWidget: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var model = WeatherModel.shared
    @ObservedObject var location = LocationModel.shared
    @Environment(\.dockUnit) var u

    var body: some View {
        let cfg = state.config
        let here = cfg.useCurrentLocation ? location.coordinate : nil
        let lat = here?.latitude ?? cfg.latitude
        let lon = here?.longitude ?? cfg.longitude
        let city = here != nil ? (location.placeName ?? "Current location") : cfg.cityName
        Tile(span: 2.9) {
            HStack(spacing: u * 0.1) {
                if let w = model.snapshot {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Image(systemName: w.symbol)
                                .symbolRenderingMode(.multicolor)
                                .font(.system(size: u * 0.24))
                            Text("\(Int(w.temp.rounded()))°")
                                .font(.system(size: u * 0.3, weight: .semibold, design: .rounded))
                        }
                        HStack(spacing: 3) {
                            if here != nil {
                                Image(systemName: "location.fill").font(.system(size: u * 0.1))
                            }
                            Text(city).lineLimit(1)
                        }
                        .font(.system(size: u * 0.14, weight: .medium))
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    ForEach(w.days.prefix(3)) { d in
                        VStack(spacing: 2) {
                            Text(d.label)
                                .font(.system(size: u * 0.12, weight: .medium))
                                .foregroundStyle(.secondary)
                            Image(systemName: d.symbol)
                                .symbolRenderingMode(.multicolor)
                                .font(.system(size: u * 0.17))
                            Text("\(Int(d.high.rounded()))°")
                                .font(.system(size: u * 0.13, weight: .semibold, design: .rounded))
                        }
                        .frame(width: u * 0.42)
                    }
                } else if model.failed {
                    Image(systemName: "wifi.slash").foregroundStyle(.secondary)
                    Text("Weather unavailable")
                        .font(.system(size: u * 0.15))
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, u * 0.16)
        }
        .help("\(city) weather. Click to open Weather")
        .onTapGesture(perform: Self.openWeatherApp)
        .onAppear {
            // Start location after this render pass, never inside it.
            if cfg.useCurrentLocation { DispatchQueue.main.async { location.start() } }
        }
        .onChange(of: cfg.useCurrentLocation) { _, on in
            on ? location.start() : location.stop()
        }
        // Rounded so small GPS jitter doesn't trigger a reload.
        .task(id: String(format: "%.2f,%.2f,%@", lat, lon, cfg.fahrenheit ? "F" : "C")) {
            while !Task.isCancelled {
                await model.load(latitude: lat, longitude: lon, fahrenheit: cfg.fahrenheit)
                try? await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
            }
        }
    }

    static func openWeatherApp() {
        let ws = NSWorkspace.shared
        if let app = ws.urlForApplication(withBundleIdentifier: "com.apple.weather") {
            ws.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        } else if let web = URL(string: "https://weather.com") {
            ws.open(web)
        }
    }
}
