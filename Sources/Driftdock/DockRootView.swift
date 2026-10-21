import SwiftUI
import AppKit

// MARK: - Environment

private struct DockUnitKey: EnvironmentKey { static let defaultValue: CGFloat = 64 }
private struct DockEdgeKey: EnvironmentKey { static let defaultValue: DockEdge = .bottom }

extension EnvironmentValues {
    /// Base tile height in points. Every widget sizes itself from this.
    var dockUnit: CGFloat {
        get { self[DockUnitKey.self] }
        set { self[DockUnitKey.self] = newValue }
    }
    var dockEdge: DockEdge {
        get { self[DockEdgeKey.self] }
        set { self[DockEdgeKey.self] = newValue }
    }
}

private struct SizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

// MARK: - Root

struct DockRootView: View {
    /// Transparent room around the dock for its shadow. The panel pushes this
    /// past the screen edge so the visible dock can sit right at the bottom.
    static let shadowPad: CGFloat = 14

    @EnvironmentObject var state: AppState
    @EnvironmentObject var panel: PanelModel
    @ObservedObject var screenshots = ScreenshotModel.shared
    @ObservedObject var devices = DevicesModel.shared
    @ObservedObject var nowPlaying = NowPlayingModel.shared
    var onSize: (CGSize) -> Void

    var body: some View {
        let cfg = state.config
        let u = 64 * CGFloat(cfg.scale) * panel.fitScale
        // Recent Screenshots only takes up room when there's a screenshot (or while rearranging).
        let enabled = cfg.widgets.filter {
            $0.enabled
                && ($0.kind != .screenshots || !screenshots.shots.isEmpty || state.arranging)
                && ($0.kind != .devices || (cfg.devicesBattery && !devices.devices.isEmpty) || state.arranging)
                && ($0.kind != .nowPlaying || !cfg.hideIdleMusic || nowPlaying.isPlaying || state.arranging)
        }
        let layout = cfg.edge.isHorizontal
            ? AnyLayout(HStackLayout(spacing: u * 0.14))
            : AnyLayout(VStackLayout(spacing: u * 0.14))

        layout {
            if enabled.isEmpty {
                Text("Right-click → Settings to add widgets")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .frame(height: u)
            }
            ForEach(enabled) { entry in
                ArrangeableWidget(kind: entry.kind)
            }
            if state.arranging {
                Button {
                    state.arranging = false
                } label: {
                    Text("Done")
                        .font(.system(size: u * 0.18, weight: .semibold))
                        .padding(.horizontal, u * 0.2)
                        .frame(height: u * 0.5)
                        .background(Capsule().fill(state.accent))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .frame(height: u)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(u * 0.14)
        .background(DockBackdrop(style: cfg.backdrop,
                                 radius: CGFloat(cfg.cornerRadius),
                                 accent: state.accent))
        .contextMenu {
            Button("Driftdock Settings…") {
                NotificationCenter.default.post(name: .driftdockOpenSettings, object: nil)
            }
            Button(state.arranging ? "Done Rearranging" : "Rearrange Widgets") {
                state.arranging.toggle()
            }
            Menu("Add Widget") {
                let off = state.config.widgets.filter { !$0.enabled }
                if off.isEmpty { Text("All widgets are on the dock") }
                ForEach(off) { entry in
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            state.setWidget(entry.kind, enabled: true)
                        }
                    } label: {
                        Label(entry.kind.title, systemImage: entry.kind.symbol)
                    }
                }
            }
            Menu("Remove Widget") {
                ForEach(state.config.widgets.filter(\.enabled)) { entry in
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            state.setWidget(entry.kind, enabled: false)
                        }
                    } label: {
                        Label(entry.kind.title, systemImage: entry.kind.symbol)
                    }
                }
            }
            Divider()
            Button("Hide Dock") {
                NotificationCenter.default.post(name: .driftdockToggleDock, object: nil)
            }
            Button("Restart Driftdock") { AppRestarter.restart() }
        }
        .padding(Self.shadowPad) // room for the shadow
        .environment(\.dockUnit, u)
        .environment(\.dockEdge, cfg.edge)
        .environment(\.colorScheme, cfg.backdrop == .light ? .light : .dark)
        .tint(state.accent)
        .fixedSize()
        .background(GeometryReader { g in
            Color.clear.preference(key: SizeKey.self, value: g.size)
        })
        .onPreferenceChange(SizeKey.self) { size in DispatchQueue.main.async { onSize(size) } }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: enabled.map(\.kind))
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: state.arranging)
    }
}

/// A widget that, in Rearrange mode, wiggles and can be dragged onto another
/// widget to take its place. Outside that mode it's just the widget.
struct ArrangeableWidget: View {
    @EnvironmentObject var state: AppState
    let kind: WidgetKind
    @State private var wiggle = false
    @State private var targeted = false

    var body: some View {
        let arranging = state.arranging
        WidgetView(kind: kind)
            .allowsHitTesting(!arranging)          // no accidental clicks while arranging
            .contextMenu {
                // Widgets with their own right-click menu (apps, music…) keep theirs.
                Button("Remove \(kind.title)") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { state.setWidget(kind, enabled: false) }
                }
                Button("Rearrange Widgets") { state.arranging = true }
                Divider()
                Button("Driftdock Settings…") {
                    NotificationCenter.default.post(name: .driftdockOpenSettings, object: nil)
                }
            }
            .overlay {
                if arranging {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(targeted ? 0.12 : 0.001))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(targeted ? state.accent : Color.white.opacity(0.35),
                                              style: StrokeStyle(lineWidth: targeted ? 2.5 : 1.5, dash: [5, 4]))
                        )
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                                .font(.system(size: 9, weight: .bold))
                                .padding(4)
                                .background(Circle().fill(state.accent))
                                .foregroundStyle(.white)
                                .offset(x: 4, y: -4)
                        }
                        .draggable(kind.rawValue) {
                            Label(kind.title, systemImage: kind.symbol)
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
                        }
                        .dropDestination(for: String.self) { items, _ in
                            guard let raw = items.first, let moved = WidgetKind(rawValue: raw) else { return false }
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                state.moveWidget(moved, to: kind)
                            }
                            return true
                        } isTargeted: { targeted = $0 }
                        .help("Drag onto another widget to swap places")
                }
            }
            .overlay(alignment: .topLeading) {
                if arranging {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            state.setWidget(kind, enabled: false)
                        }
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.red))
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.8), lineWidth: 1))
                            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    }
                    .buttonStyle(.plain)
                    .offset(x: -6, y: -6)
                    .help("Remove \(kind.title) from the dock")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .rotationEffect(.degrees(arranging ? (wiggle ? 1.1 : -1.1) : 0))
            .animation(arranging ? .easeInOut(duration: 0.14).repeatForever(autoreverses: true) : .default,
                       value: wiggle)
            .onAppear { wiggle = arranging }
            .onChange(of: arranging) { _, on in wiggle = on }
    }
}

struct WidgetView: View {
    let kind: WidgetKind

    var body: some View {
        switch kind {
        case .clock: ClockWidget()
        case .weather: WeatherWidget()
        case .apps: AppsWidget()
        case .screenshots: ScreenshotsWidget()
        case .devices: DevicesWidget()
        case .nowPlaying: NowPlayingWidget()
        case .stats: StatsWidget()
        case .todos: TodoWidget()
        case .pomodoro: PomodoroWidget()
        case .clipboard: ClipboardWidget()
        case .search: SearchWidget()
        case .toggles: TogglesWidget()
        }
    }
}

// MARK: - Backdrop

struct DockBackdrop: View {
    let style: Backdrop
    let radius: CGFloat
    let accent: Color

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape
                .fill(Color.black.opacity(0.25))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
            VisualEffect(material: style == .light ? .popover : .hudWindow,
                         dark: style != .light,
                         radius: radius)
            switch style {
            case .dark: shape.fill(Color.black.opacity(0.35))
            case .tinted: shape.fill(accent.opacity(0.22))
            case .glass, .light: EmptyView()
            }
            shape.strokeBorder(Color.white.opacity(style == .light ? 0.55 : 0.12), lineWidth: 1)
        }
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var dark: Bool
    var radius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        v.layer?.cornerRadius = radius
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
    }
}

// MARK: - Tile

/// The rounded card every widget sits in. `span` is width in dock units, `rows` is height.
struct Tile<Content: View>: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dockUnit) var u
    var span: CGFloat = 1
    var rows: CGFloat = 1
    @ViewBuilder var content: () -> Content

    var body: some View {
        let radius = max(6, CGFloat(state.config.cornerRadius) - u * 0.14)
        content()
            .frame(width: u * span, height: u * rows)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    private var fill: Color {
        switch state.config.backdrop {
        case .light: return Color.black.opacity(0.05)
        case .tinted: return state.accent.opacity(0.16)
        case .glass, .dark: return Color.white.opacity(0.07)
        }
    }
}

/// Small round icon button used inside widgets.
struct DockIconButton: View {
    @Environment(\.dockUnit) var u
    let symbol: String
    var size: CGFloat = 0.22
    var help: String = ""
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: u * size, weight: .semibold))
                .frame(width: u * (size + 0.14), height: u * (size + 0.14))
                .background(Circle().fill(Color.primary.opacity(hover ? 0.14 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

// MARK: - Focus borrowing for popovers

/// The dock never takes focus on its own. Popovers with text fields briefly
/// activate the app, then hand focus back to whatever you were using.
enum FocusBroker {
    private static var previous: NSRunningApplication?

    static func borrow() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previous = front
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    static func giveBack() {
        if NSApp.isActive { previous?.activate(options: []) }
        previous = nil
    }
}

extension View {
    func borrowsFocus() -> some View {
        onAppear { FocusBroker.borrow() }
            .onDisappear { FocusBroker.giveBack() }
    }
}
