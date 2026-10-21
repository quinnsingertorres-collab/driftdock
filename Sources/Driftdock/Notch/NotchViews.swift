import SwiftUI
import AppKit
import AVFoundation
import EventKit

// MARK: - Shape

/// A notch outline: flares out into the screen edge at the top, rounded at the bottom.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let t = topRadius, b = bottomRadius
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Root

struct NotchRootView: View {
    @EnvironmentObject var model: NotchModel
    @EnvironmentObject var state: AppState
    @ObservedObject var music = NowPlayingModel.shared
    @ObservedObject var stats = StatsModel.shared
    @ObservedObject var live = LiveActivityCenter.shared
    @ObservedObject var volume = VolumeMonitor.shared
    @ObservedObject var downloads = DownloadsMonitor.shared
    @ObservedObject var focus = PomodoroModel.shared
    @ObservedObject var shelf = ShelfModel.shared
    @ObservedObject var voice = VoiceTranscriber.shared
    @ObservedObject var brightness = Brightness.shared
    @ObservedObject var timers = TimerCenter.shared
    @ObservedObject var calls = CallMonitor.shared

    /// What the closed notch shows on its sides, most important first.
    private enum Activity: Equatable {
        case none, flash(LiveActivityCenter.Flash), volume, downloading, downloaded(String)
        case focus, music, charging, shelf(Int), transcribing, device(LiveActivityCenter.DeviceNotice), brightness
        case timer, call
    }

    private var activity: Activity {
        let cfg = state.config
        if voice.isRunning { return .transcribing }
        if cfg.notchLiveCalls && calls.call != nil { return .call }
        if let f = live.flash { return .flash(f) }
        if let d = live.device { return .device(d) }
        if (cfg.notchVolumeHUD || cfg.replaceSystemHUD) && volume.showing { return .volume }
        if brightness.showing { return .brightness }
        if cfg.notchDownloads, let done = downloads.finished { return .downloaded(done.lastPathComponent) }
        if cfg.notchDownloads && !downloads.active.isEmpty { return .downloading }
        if cfg.notchLiveFocus && focus.running { return .focus }
        if cfg.notchLiveTimers && timers.featured != nil { return .timer }
        if cfg.notchLiveMusic && music.isPlaying { return .music }
        if cfg.notchLiveBattery && stats.charging && stats.battery != nil { return .charging }
        if cfg.notchLiveShelf && cfg.notchShelf && !shelf.items.isEmpty { return .shelf(shelf.items.count) }
        return .none
    }

    /// Width of each side "wing" next to the notch.
    private func wingWidth(_ a: Activity, h: CGFloat) -> CGFloat {
        switch a {
        case .none: return 0
        case .flash, .downloaded, .transcribing: return 140
        case .volume, .brightness: return h * 4.2
        case .device: return 150
        case .charging, .focus, .timer: return h * 2.4
        case .call: return h * 2.6
        case .downloading, .shelf: return h * 1.6
        case .music: return h * 1.15
        }
    }

    var body: some View {
        let notch = model.notchSize
        let island = model.isIsland
        let open = model.expanded
        let act = activity
        let banner = open ? nil : live.banner
        let wing = banner != nil ? max(wingWidth(act, h: notch.height), 110) : wingWidth(act, h: notch.height)
        // Some activities grow the notch downward: dictation shows text, devices show a ring.
        let grow: CGFloat = open ? 0 : growHeight(act)
        let top: CGFloat = island ? 0 : (open ? 12 : 6)
        let width = open ? NotchModel.openWidth : notch.width + wing * 2 + top * 2
        let height = open ? notch.height + NotchModel.openBodyHeight
            : notch.height + (banner != nil ? NotchModel.bannerHeight : 0) + grow
        let bottom: CGFloat = open ? 30 : (banner != nil || grow > 0 ? 24 : (island ? notch.height / 2 : 10))
        let glass = open && state.config.notchFinish == "glass"

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                background(top: top, bottom: bottom, island: island, glass: glass)

                // Album art glows up from the bottom of the player, like Droppy.
                if open && model.tab == .home, let art = music.artwork {
                    Image(nsImage: art)
                        .resizable()
                        .scaledToFill()
                        .frame(width: width, height: height)
                        .blur(radius: 36)
                        .saturation(1.4)
                        .opacity(0.5)
                        .mask(LinearGradient(colors: [.clear, .clear, .black], startPoint: .top, endPoint: .bottom))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                if open {
                    NotchOpenContent(notch: notch)
                        .padding(.horizontal, top + 16)
                        .transition(.notchReveal)
                } else {
                    VStack(spacing: 0) {
                        collapsedWings(act, notch: notch, wing: wing)
                            .padding(.horizontal, top)
                            .id(activityKey(act))
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                        if case .device(let d) = act {
                            DeviceConnectedCard(device: d)
                                .padding(.horizontal, top + 18)
                                .frame(height: 56)
                                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
                        }
                        if act == .transcribing {
                            TranscriptView()
                                .padding(.horizontal, top + 18)
                                .frame(height: 52, alignment: .top)
                                .transition(.opacity)
                        }
                        if let banner {
                            BannerRow(banner: banner)
                                .padding(.horizontal, top + 18)
                                .frame(height: NotchModel.bannerHeight - 8)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .transition(.opacity)
                }
            }
            .frame(width: width, height: height)
            .clipShape(shape(top: top, bottom: bottom, island: island))
            .shadow(color: .black.opacity(open || island ? 0.35 : 0), radius: 10, y: 5)
            .padding(.top, island ? NotchModel.islandInset : 0)
            .dropDestination(for: URL.self) { urls, _ in
                guard state.config.notchShelf else { return false }
                ShelfModel.shared.add(urls)
                model.tab = .shelf
                return true
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: act)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: banner)

            if open {
                NotchTabPill()
                    .padding(.top, NotchModel.pillGap)
                    // Pops out of the notch like a dividing Dynamic Island.
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.2, anchor: .top).combined(with: .opacity)
                            .animation(.spring(response: 0.42, dampingFraction: 0.68).delay(0.06)),
                        removal: .scale(scale: 0.2, anchor: .top).combined(with: .opacity)))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .tint(state.accent)
    }

    private func growHeight(_ a: Activity) -> CGFloat {
        switch a {
        case .transcribing: return 58
        case .device: return 62
        default: return 0
        }
    }

    /// Stable identity per kind of activity, so switching kinds animates (shrinks in place).
    private func activityKey(_ a: Activity) -> String {
        switch a {
        case .none: return "none"
        case .flash: return "flash"
        case .volume: return "volume"
        case .downloading: return "downloading"
        case .downloaded: return "downloaded"
        case .focus: return "focus"
        case .music: return "music"
        case .charging: return "charging"
        case .shelf: return "shelf"
        case .transcribing: return "transcribing"
        case .device: return "device"
        case .brightness: return "brightness"
        case .timer: return "timer"
        case .call: return "call"
        }
    }

    /// On a notch the shape flares into the screen edge; on other displays it's a floating island.
    private func shape(top: CGFloat, bottom: CGFloat, island: Bool) -> AnyShape {
        island ? AnyShape(RoundedRectangle(cornerRadius: bottom, style: .continuous))
               : AnyShape(NotchShape(topRadius: top, bottomRadius: bottom))
    }

    @ViewBuilder
    private func background(top: CGFloat, bottom: CGFloat, island: Bool, glass: Bool) -> some View {
        let s = shape(top: top, bottom: bottom, island: island)
        if glass {
            s.fill(.ultraThinMaterial)
            s.fill(Color.black.opacity(0.45))
        } else {
            s.fill(Color.black)
        }
    }

    @ViewBuilder
    private func collapsedWings(_ act: Activity, notch: CGSize, wing: CGFloat) -> some View {
        let h = notch.height
        let wide = wing > h * 2
        HStack(spacing: 0) {
            Group {
                switch act {
                case .flash(let f):
                    Image(systemName: f.symbol).foregroundStyle(state.accent)
                case .volume:
                    HStack(spacing: 8) {
                        Image(systemName: volume.muted || volume.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        Text("Volume")
                    }
                case .device:
                    EmptyView()   // the card below says it all
                case .brightness:
                    HStack(spacing: 8) {
                        Image(systemName: "sun.max.fill")
                        Text("Brightness")
                    }
                case .transcribing:
                    HStack(spacing: 6) {
                        PulsingDot()
                        Text("Listening")
                    }
                case .downloading:
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(state.accent)
                case .downloaded:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .focus:
                    ProgressRing(progress: focus.progress, color: .orange,
                                 symbol: focus.phase == .focus ? "brain.head.profile" : "cup.and.saucer.fill")
                        .frame(width: h * 0.62, height: h * 0.62)
                case .timer:
                    TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                        if let t = timers.featured {
                            if t.kind == .timer {
                                ProgressRing(progress: t.progress(at: ctx.date), color: .orange)
                                    .frame(width: h * 0.55, height: h * 0.55)
                            } else {
                                Image(systemName: "stopwatch").foregroundStyle(.orange)
                            }
                        }
                    }
                case .call:
                    Button { calls.showCallApp() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "phone.fill").foregroundStyle(.green)
                            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                Text(TimerCenter.clock(ctx.date.timeIntervalSince(calls.call?.startedAt ?? ctx.date)))
                                    .monospacedDigit()
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help("\(calls.call?.name ?? "Call"): click to show")
                case .music:
                    ArtworkView(image: music.artwork, size: h - 10, radius: 6)
                case .charging:
                    HStack(spacing: 5) {
                        Image(systemName: "bolt.fill").foregroundStyle(.green)
                        Text("Charging")
                    }
                case .shelf:
                    Image(systemName: "tray.fill")
                case .none:
                    EmptyView()
                }
            }
            .font(.system(size: h * 0.38, weight: .semibold))
            .frame(width: wing, alignment: wide ? .leading : .center)
            .padding(.leading, wide ? 10 : 0)

            Spacer(minLength: notch.width)

            Group {
                switch act {
                case .flash(let f):
                    Text(f.text).lineLimit(1).truncationMode(.middle)
                case .volume:
                    HStack(spacing: 7) {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.2))
                                Capsule().fill(volume.muted ? Color.red : Color.green)
                                    .frame(width: g.size.width * CGFloat(volume.muted ? 1 : volume.volume))
                            }
                        }
                        .frame(width: h * 2, height: 5)
                        Text("\(Int((volume.volume * 100).rounded()))")
                            .font(.system(size: h * 0.46, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .frame(width: h * 0.9, alignment: .trailing)
                    }
                case .downloading:
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        if downloads.active.count > 1 { Text("\(downloads.active.count)") }
                    }
                case .downloaded(let name):
                    Text(name).lineLimit(1).truncationMode(.middle)
                case .device:
                    EmptyView()
                case .brightness:
                    HStack(spacing: 7) {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.2))
                                Capsule().fill(Color.white)
                                    .frame(width: g.size.width * CGFloat(brightness.level))
                            }
                        }
                        .frame(width: h * 2, height: 5)
                        Text("\(Int((brightness.level * 100).rounded()))")
                            .font(.system(size: h * 0.46, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .frame(width: h * 0.9, alignment: .trailing)
                    }
                case .transcribing:
                    Button { voice.stop() } label: {
                        Image(systemName: "stop.circle.fill").foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Stop and copy the transcript")
                case .timer:
                    TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                        if let t = timers.featured {
                            Text((t.kind == .timer ? "• " : "") +
                                 TimerCenter.clock(t.kind == .timer ? t.remaining(at: ctx.date) : t.elapsed(at: ctx.date)))
                                .monospacedDigit()
                                .foregroundStyle(.orange)
                        }
                    }
                case .call:
                    HStack(spacing: 6) {
                        CallWave().frame(width: h * 0.9, height: h * 0.4)
                        Button { calls.toggleMic() } label: {
                            Image(systemName: calls.micMuted ? "mic.slash.fill" : "mic.fill")
                                .foregroundStyle(calls.micMuted ? Color.red : Color.white)
                        }
                        .buttonStyle(.plain)
                        .help(calls.micMuted ? "Unmute microphone" : "Mute microphone")
                    }
                case .focus:
                    Text("• " + String(format: "%02d:%02d", Int(focus.remaining) / 60, Int(focus.remaining) % 60))
                        .monospacedDigit()
                        .foregroundStyle(.orange)
                case .music:
                    EqualizerBars(playing: music.isPlaying, color: state.accent)
                        .frame(width: h * 0.62, height: h * 0.42)
                case .charging:
                    if let b = stats.battery {
                        HStack(spacing: 4) {
                            Text("\(Int((b * 100).rounded()))%")
                            Image(systemName: "battery.75percent")
                        }
                        .foregroundStyle(.green)
                    }
                case .shelf(let count):
                    Text("\(count)").foregroundStyle(state.accent)
                case .none:
                    EmptyView()
                }
            }
            .font(.system(size: h * 0.36, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: wing, alignment: wide ? .trailing : .center)
            .padding(.trailing, wide ? 10 : 0)
        }
        .frame(height: h)
    }
}

/// Two-line notice under the closed notch: "Full Battery 100% / Your Mac is fully charged."
/// Little green waveform for an active call.
struct CallWave: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 1.5) {
                ForEach(0..<7, id: \.self) { i in
                    Capsule()
                        .fill(Color.green)
                        .frame(maxHeight: .infinity)
                        .scaleEffect(y: 0.3 + 0.7 * abs(sin(t * 6 + Double(i) * 0.9)), anchor: .center)
                }
            }
        }
    }
}

/// "AirPods Pro connected": a big device glyph, the name, and a ring per battery.
struct DeviceConnectedCard: View {
    let device: LiveActivityCenter.DeviceNotice
    @State private var appeared = false

    private var rings: [(String, Int)] {
        var r: [(String, Int)] = []
        if let l = device.left { r.append(("L", l)) }
        if let rt = device.right { r.append(("R", rt)) }
        if let c = device.caseLevel { r.append(("Case", c)) }
        if r.isEmpty, let m = device.level { r.append(("", m)) }
        return r
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.white.opacity(0.08))
                Image(systemName: device.symbol)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.white)
                    .symbolEffect(.bounce, value: appeared)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 1) {
                Text("Connected")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Text(device.name)
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            HStack(spacing: 10) {
                ForEach(Array(rings.enumerated()), id: \.offset) { _, ring in
                    VStack(spacing: 2) {
                        BatteryRing(level: appeared ? ring.1 : 0)
                            .frame(width: 30, height: 30)
                        if !ring.0.isEmpty {
                            Text(ring.0)
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .onAppear {
            withAnimation(.spring(response: 0.9, dampingFraction: 0.85).delay(0.15)) { appeared = true }
        }
    }
}

/// Green ring with the battery level inside, for connecting devices.
struct BatteryRing: View {
    let level: Int

    var body: some View {
        let color: Color = level <= 20 ? .red : .green
        ZStack {
            Circle().stroke(color.opacity(0.25), lineWidth: 3)
            Circle().trim(from: 0, to: max(0.001, CGFloat(level) / 100))
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(level)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(color)
        }
    }
}

/// Red dot that breathes while dictation is listening.
struct PulsingDot: View {
    @State private var on = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 8, height: 8)
            .scaleEffect(on ? 1.25 : 0.8)
            .opacity(on ? 1 : 0.55)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

/// The live transcript under the notch: settled words bright, in-progress words dim.
struct TranscriptView: View {
    @ObservedObject var voice = VoiceTranscriber.shared
    @ObservedObject var brightness = Brightness.shared
    @ObservedObject var timers = TimerCenter.shared
    @ObservedObject var calls = CallMonitor.shared

    var body: some View {
        (Text(voice.stable.isEmpty && voice.live.isEmpty ? "Start talking…" : voice.stable)
            .foregroundColor(voice.stable.isEmpty && voice.live.isEmpty ? .white.opacity(0.4) : .white)
         + Text(voice.live.isEmpty ? "" : (voice.stable.isEmpty ? "" : " ") + voice.live)
            .foregroundColor(.white.opacity(0.45)))
            .font(.system(size: 12, weight: .medium))
            .lineLimit(3)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeOut(duration: 0.15), value: voice.stable + voice.live)
    }
}

/// The open panel drops out of the notch with a soft blur and a vertical stretch (Droppy 14).
struct NotchRevealModifier: ViewModifier {
    let progress: CGFloat   // 0 hidden, 1 shown

    func body(content: Content) -> some View {
        content
            .blur(radius: (1 - progress) * 10)
            .scaleEffect(x: 1, y: 0.75 + 0.25 * progress, anchor: .top)
            .opacity(Double(progress))
    }
}

extension AnyTransition {
    static var notchReveal: AnyTransition {
        .modifier(active: NotchRevealModifier(progress: 0), identity: NotchRevealModifier(progress: 1))
    }
}

struct BannerRow: View {
    let banner: LiveActivityCenter.Banner

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: banner.symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(banner.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(banner.title).font(.system(size: 14, weight: .bold))
                    if let v = banner.value {
                        Text(v).font(.system(size: 14, weight: .bold)).foregroundStyle(banner.tint)
                    }
                }
                Text(banner.subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if let t = banner.trailing {
                Image(systemName: t).font(.system(size: 16, weight: .bold))
            }
        }
        .foregroundStyle(.white)
    }
}

struct NotchOpenContent: View {
    @EnvironmentObject var model: NotchModel
    @EnvironmentObject var state: AppState
    @ObservedObject var stats = StatsModel.shared
    @ObservedObject var devices = DevicesModel.shared
    @ObservedObject var music = NowPlayingModel.shared
    let notch: CGSize

    var body: some View {
        VStack(spacing: 6) {
            // Header row lives beside the physical notch.
            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    if state.config.clockInNotch {
                        TimelineView(.periodic(from: .now, by: state.config.clockSeconds ? 1 : 15)) { ctx in
                            Text(ClockFormat.time(ctx.date, cfg: state.config))
                                .font(.system(size: 13, weight: ClockFormat.weight(state.config.clockWeight),
                                              design: ClockFormat.design(state.config.clockFont)))
                                .monospacedDigit()
                        }
                    }
                    Text(model.tab == .home ? (music.player ?? "Now Playing") : NotchModel.title(model.tab))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                    Spacer(minLength: 0)
                }
                Spacer(minLength: notch.width)
                HStack(spacing: 7) {
                    Spacer(minLength: 0)
                    if state.config.devicesBattery, let d = devices.devices.first, let level = d.summary {
                        HStack(spacing: 3) {
                            Image(systemName: d.symbol)
                            Text("\(level)%").foregroundStyle(level <= 20 ? Color.red : Color.white)
                        }
                        .lineLimit(1)
                        .fixedSize()
                        .help(deviceHelp(d))
                    }
                    if let b = stats.battery {
                        // Icon only: the percentage is in the tooltip, so the AirPods level has room.
                        HStack(spacing: 2) {
                            if stats.charging { Image(systemName: "bolt.fill").foregroundStyle(.green) }
                            Image(systemName: batterySymbol(b)).foregroundStyle(b < 0.2 ? .red : .white)
                        }
                        .fixedSize()
                        .help("Mac battery \(Int((b * 100).rounded()))%")
                    }
                    Button {
                        NotificationCenter.default.post(name: .driftdockOpenSettings, object: nil)
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize()
                    .help("Driftdock Settings")
                }
                .font(.system(size: 11, weight: .bold))
            }
            .frame(height: notch.height)

            Group {
                switch model.tab {
                case .home: NotchHome()
                case .shelf: NotchShelf()
                case .calendar: NotchToday()
                case .tools: NotchTools()
                case .timers: NotchTimers()
                case .mixer: MixerView()
                case .mirror: NotchMirror()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 14)
        }
        .foregroundStyle(.white)
        .onAppear {
            if !NotchModel.tabs(state.config).contains(model.tab) { model.tab = .home }
        }
    }

    private func deviceHelp(_ d: DevicesModel.Device) -> String {
        var parts: [String] = []
        if let l = d.left { parts.append("L \(l)%") }
        if let r = d.right { parts.append("R \(r)%") }
        if let c = d.caseLevel { parts.append("Case \(c)%") }
        if parts.isEmpty, let m = d.main { parts.append("\(m)%") }
        return d.name + (parts.isEmpty ? "" : " · " + parts.joined(separator: " · "))
    }

    private func batterySymbol(_ b: Double) -> String {
        switch b {
        case ..<0.13: return "battery.0percent"
        case ..<0.38: return "battery.25percent"
        case ..<0.63: return "battery.50percent"
        case ..<0.88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

/// Droppy-style floating tab bar under the open notch.
struct NotchTabPill: View {
    @EnvironmentObject var model: NotchModel
    @EnvironmentObject var state: AppState
    @Namespace private var selection

    private var addMenu: some View {
        Menu("Add Tab") { addMenuItems }
    }

    @ViewBuilder
    private var addMenuItems: some View {
        let current = NotchModel.tabs(state.config)
        let missing = NotchModel.Tab.allCases.filter { !current.contains($0) && ($0 != .mixer || MixerModel.isSupported) }
        if missing.isEmpty { Text("All tabs are showing") }
        ForEach(missing, id: \.self) { t in
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { NotchModel.addTab(t) }
            } label: {
                Label(NotchModel.title(t), systemImage: NotchModel.icon(t))
            }
        }
        Divider()
        Button("Customize Tabs…") { NotificationCenter.default.post(name: .driftdockOpenSettings, object: nil) }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(NotchModel.tabs(state.config), id: \.self) { tab in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.tab = tab }
                } label: {
                    Image(systemName: NotchModel.icon(tab))
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 36, height: NotchModel.pillHeight - 8)
                        .background {
                            if model.tab == tab {
                                Capsule()
                                    .fill(Color.white.opacity(0.16))
                                    .matchedGeometryEffect(id: "tab", in: selection)
                            }
                        }
                        .foregroundStyle(model.tab == tab ? Color.white : Color.white.opacity(0.5))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(NotchModel.title(tab))
                .draggable(tab.rawValue) {
                    Image(systemName: NotchModel.icon(tab))
                        .font(.system(size: 14, weight: .semibold))
                        .padding(8)
                        .background(Circle().fill(Color.black))
                        .foregroundStyle(.white)
                }
                .dropDestination(for: String.self) { items, _ in
                    guard let raw = items.first, let moved = NotchModel.Tab(rawValue: raw) else { return false }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { NotchModel.moveTab(moved, to: tab) }
                    return true
                }
                .contextMenu {
                    Button("Move Left") { withAnimation { NotchModel.shiftTab(tab, by: -1) } }
                    Button("Move Right") { withAnimation { NotchModel.shiftTab(tab, by: 1) } }
                    Divider()
                    Button("Remove \(NotchModel.title(tab))") {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            if model.tab == tab { model.tab = NotchModel.tabs(state.config).first { $0 != tab } ?? .home }
                            NotchModel.removeTab(tab)
                        }
                    }
                    .disabled(NotchModel.tabs(state.config).count <= 1)
                    addMenu
                }
            }
            let missing = NotchModel.Tab.allCases.filter { !NotchModel.tabs(state.config).contains($0) }
            if !missing.isEmpty {
                Menu {
                    addMenuItems
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 24, height: NotchModel.pillHeight - 8)
                        .foregroundStyle(Color.white.opacity(0.4))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add a tab")
            }
        }
        .padding(4)
        .frame(height: NotchModel.pillHeight)
        .background(Capsule().fill(Color.black.opacity(0.88)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }
}

// MARK: - Home: the player

struct NotchHome: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var music = NowPlayingModel.shared

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Button(action: music.openPlayer) {
                    ArtworkView(image: music.artwork, size: 52, radius: 13)
                        .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
                }
                .buttonStyle(.plain)
                .help("Open \(music.player ?? NowPlayingModel.idleAppName)")

                VStack(alignment: .leading, spacing: 2) {
                    Text(music.title.isEmpty ? "Nothing playing" : music.title)
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(1)
                    Text(music.artist.isEmpty ? "Press play to start \(NowPlayingModel.idleAppName)" : music.artist)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                EqualizerBars(playing: music.isPlaying, color: state.accent)
                    .frame(width: 24, height: 14)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 4)
            }
            .frame(height: 52)

            NotchProgressBar()

            HStack {
                bigButton("list.bullet", 13, help: "Open \(music.player ?? NowPlayingModel.idleAppName)") { music.openPlayer() }
                Spacer()
                bigButton("backward.fill", 18, help: "Previous") { music.command("previous track") }
                Spacer()
                bigButton(music.isPlaying ? "pause.fill" : "play.fill", 24, help: "Play/Pause") { music.command("playpause") }
                Spacer()
                bigButton("forward.fill", 18, help: "Next") { music.command("next track") }
                Spacer()
                bigButton("laptopcomputer", 14, help: "Sound output") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func bigButton(_ symbol: String, _ size: CGFloat, help: String, action: @escaping () -> Void) -> some View {
        NotchControlButton(symbol: symbol, size: size, action: action).help(help)
    }
}

/// Big transport buttons that dip slightly when pressed.
struct NotchControlButton: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .bold))
                .frame(width: size + 16, height: 28)
                .contentShape(Rectangle())
                .opacity(hover ? 1 : 0.92)
                .scaleEffect(hover ? 1.08 : 1)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

/// 0:02 ━━━━━━━━━━ -3:16, click or drag to seek.
struct NotchProgressBar: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var music = NowPlayingModel.shared
    @State private var dragFraction: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let duration = music.duration
            let pos = music.currentPosition(at: ctx.date)
            let fraction = dragFraction ?? (duration > 0 ? pos / duration : 0)
            HStack(spacing: 8) {
                Text(Self.time(dragFraction.map { $0 * duration } ?? pos))
                    .frame(width: 34, alignment: .leading)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule().fill(Color.white.opacity(0.9))
                            .frame(width: max(8, g.size.width * fraction))
                        Circle().fill(Color.white)
                            .frame(width: 9, height: 9)
                            .offset(x: max(0, g.size.width * fraction - 4.5))
                            .opacity(duration > 0 ? 1 : 0)
                    }
                    .frame(height: 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in dragFraction = max(0, min(1, v.location.x / g.size.width)) }
                        .onEnded { v in
                            music.seek(to: max(0, min(1, v.location.x / g.size.width)))
                            dragFraction = nil
                        })
                }
                .frame(height: 12)
                Text(duration > 0 ? "-" + Self.time(max(0, duration - (dragFraction.map { $0 * duration } ?? pos))) : "--:--")
                    .frame(width: 40, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.75))
            .disabled(duration <= 0)
        }
    }

    static func time(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.white.opacity(0.1))
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.35))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Little bouncing bars shown beside the notch while music plays.
struct EqualizerBars: View {
    let playing: Bool
    let color: Color
    var bars: Int = 5
    @ObservedObject private var spectrum = SpectrumModel.shared
    @State private var listening = false

    var body: some View {
        Group {
            if playing && spectrum.isLive && !spectrum.levels.isEmpty {
                // Real music: bass on the left, treble on the right.
                HStack(alignment: .center, spacing: 2) {
                    ForEach(0..<bars, id: \.self) { i in
                        Capsule()
                            .fill(color)
                            .frame(maxHeight: .infinity)
                            .scaleEffect(y: 0.08 + 0.92 * CGFloat(level(i)), anchor: .center)
                    }
                }
                .animation(.easeOut(duration: 0.05), value: spectrum.levels)
            } else {
                fallback
            }
        }
        .onAppear { setListening(playing) }
        .onChange(of: playing) { _, now in setListening(now) }
        .onDisappear { setListening(false) }
    }

    /// Averages the analyzer's bands down to this many bars.
    private func level(_ i: Int) -> Float {
        let levels = spectrum.levels
        let n = levels.count
        guard n > 0 else { return 0 }
        let start = i * n / bars
        let end = max(start + 1, (i + 1) * n / bars)
        var sum: Float = 0
        for k in start..<min(end, n) { sum += levels[k] }
        return sum / Float(min(end, n) - start)
    }

    private func setListening(_ on: Bool) {
        guard on != listening else { return }
        listening = on
        on ? spectrum.retain() : spectrum.release()
    }

    /// Gentle animation for when the audio can't be read (permission not given yet, etc.).
    private var fallback: some View {
        TimelineView(.animation(minimumInterval: 0.08, paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<bars, id: \.self) { i in
                    let phase = sin(t * (7 + Double(i) * 2.1) + Double(i) * 1.3)
                    Capsule()
                        .fill(color)
                        .frame(maxHeight: .infinity)
                        .scaleEffect(y: playing ? 0.15 + 0.85 * abs(phase) : 0.3, anchor: .center)
                }
            }
            .animation(.easeInOut(duration: 0.12), value: t)
        }
    }
}

// MARK: - Calendar

final class CalendarModel: ObservableObject {
    static let shared = CalendarModel()

    @Published private(set) var events: [EKEvent] = []
    @Published private(set) var status: EKAuthorizationStatus = .notDetermined

    private let store = EKEventStore()

    private init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    var hasAccess: Bool { status == .fullAccess }

    func refresh() {
        status = EKEventStore.authorizationStatus(for: .event)
        guard hasAccess else { events = []; return }
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: now)) ?? now
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-30 * 60), end: end, calendars: nil)
        events = store.events(matching: predicate)
            .filter { $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
            .prefix(3)
            .map { $0 }
    }

    func requestAccess() {
        store.requestFullAccessToEvents { [weak self] _, _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }
}

struct NotchCalendar: View {
    @ObservedObject var cal = CalendarModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Date(), format: .dateTime.weekday(.wide).month(.abbreviated).day())
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            if !cal.hasAccess {
                Text("See your next events here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                Button("Show calendar") { cal.requestAccess() }
                    .controlSize(.small)
            } else if cal.events.isEmpty {
                Text("Nothing else today or tomorrow")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            } else {
                ForEach(cal.events, id: \.eventIdentifier) { e in
                    HStack(alignment: .top, spacing: 6) {
                        Capsule()
                            .fill(Color(nsColor: e.calendar.color))
                            .frame(width: 3, height: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.title ?? "Event")
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                            Text(timeLabel(e))
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .onAppear { cal.refresh() }
    }

    private func timeLabel(_ e: EKEvent) -> String {
        if e.isAllDay { return Calendar.current.isDateInToday(e.startDate) ? "All day" : "Tomorrow, all day" }
        let time = e.startDate.formatted(date: .omitted, time: .shortened)
        if e.startDate <= Date() { return "Now · until \(e.endDate.formatted(date: .omitted, time: .shortened))" }
        return Calendar.current.isDateInToday(e.startDate) ? time : "Tomorrow \(time)"
    }
}

// MARK: - Today (calendar, weather, to-dos)

struct NotchToday: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var weather = WeatherModel.shared
    @ObservedObject var todos = TodoStore.shared
    @State private var draft = ""

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if state.config.notchCalendar {
                NotchCalendar().frame(maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1)
            }
            VStack(alignment: .leading, spacing: 6) {
                if let w = weather.snapshot {
                    HStack(spacing: 6) {
                        Image(systemName: w.symbol).symbolRenderingMode(.multicolor)
                        Text("\(Int(w.temp.rounded()))°").font(.system(size: 13, weight: .bold))
                        ForEach(w.days.prefix(2)) { d in
                            Text("\(d.label) \(Int(d.high.rounded()))°")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                }
                ForEach(todos.items.filter { !$0.done }.prefix(3)) { item in
                    Button {
                        if let i = todos.items.firstIndex(where: { $0.id == item.id }) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { todos.items[i].done = true }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "circle").font(.system(size: 11))
                            Text(item.text).font(.system(size: 11)).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
                TextField("Add a to-do", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .onSubmit {
                        todos.add(draft)
                        draft = ""
                    }
                Spacer(minLength: 0)
            }
            .frame(width: 170, alignment: .leading)
        }
    }
}

// MARK: - Shelf

struct NotchShelf: View {
    @ObservedObject var shelf = ShelfModel.shared
    @State private var targeted = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(targeted ? 0.6 : 0.18), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            if shelf.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 26))
                    Text("Drop files here to hold them")
                        .font(.system(size: 12))
                }
                .foregroundStyle(.white.opacity(0.55))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(shelf.items, id: \.self) { url in
                            ShelfItem(url: url)
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .overlay(alignment: .topTrailing) {
                    ShelfActionsMenu().padding(6)
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            shelf.add(urls)
            return true
        } isTargeted: { targeted = $0 }
    }
}

struct ShelfItem: View {
    @ObservedObject var shelf = ShelfModel.shared
    let url: URL
    @State private var hover = false

    var body: some View {
        let selected = shelf.selection.contains(url)
        VStack(spacing: 4) {
            Image(nsImage: IconCache.icon(for: url.path))
                .resizable()
                .frame(width: 52, height: 52)
            Text(url.lastPathComponent)
                .font(.system(size: 10))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 76)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? AppState.shared.accent.opacity(0.4) : Color.white.opacity(hover ? 0.1 : 0)))
        .overlay(alignment: .topTrailing) {
            if hover {
                Button { ShelfModel.shared.remove(url) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .onTapGesture { shelf.toggleSelection(url) }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .help("\(url.lastPathComponent)\nDrag out to use it · click to select · double-click to open")
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Remove from Shelf") { ShelfModel.shared.remove(url) }
        }
    }
}

// MARK: - Tools

struct NotchTools: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var awake = StayAwake.shared
    @ObservedObject var focus = PomodoroModel.shared

    var body: some View {
        let mins = Int(focus.remaining) / 60
        let secs = Int(focus.remaining) % 60
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            tool(awake.isOn ? "Awake" : "Stay Awake", "cup.and.saucer.fill", on: awake.isOn) { awake.toggle() }
            tool(focus.running ? String(format: "%02d:%02d", mins, secs) : "Focus", "timer", on: focus.running) { focus.toggle() }
            tool("Pick Color", "eyedropper") { ScreenColorPicker.pick() }
            tool("Launcher", "bolt.fill") { LauncherController.shared.toggle() }
            tool("Clipboard", "doc.on.clipboard") { ClipboardPickerController.shared.toggle() }
            tool("Screenshot", "camera.viewfinder") {
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app"),
                                                   configuration: NSWorkspace.OpenConfiguration())
            }
            tool("Dark Mode", "circle.lefthalf.filled") {
                NowPlayingModel.run("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
            }
            tool("File Tray", "tray.full.fill") { FileTrayController.shared.show() }
            tool("Stopwatch", "stopwatch") { TimerCenter.shared.addStopwatch() }
            tool("Dictate", "waveform", on: VoiceTranscriber.shared.isRunning) { VoiceTranscriber.shared.toggle() }
        }
    }

    private func tool(_ title: String, _ symbol: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                Text(title).font(.system(size: 10, weight: .medium)).lineLimit(1).monospacedDigit()
            }
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(on ? state.accent.opacity(0.55) : Color.white.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Mirror

final class MirrorNSView: NSView {
    private let session = AVCaptureSession()
    private let preview = AVCaptureVideoPreviewLayer()
    private var configured = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        preview.videoGravity = .resizeAspectFill
        layer?.addSublayer(preview)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        preview.frame = bounds
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted { DispatchQueue.main.async { self.configureAndRun() } }
            }
        default:
            break
        }
    }

    func stop() {
        let s = session
        DispatchQueue.global(qos: .userInitiated).async { s.stopRunning() }
    }

    private func configureAndRun() {
        if !configured {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            preview.session = session
            if let conn = preview.connection, conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = true
            }
            configured = true
        }
        let s = session
        DispatchQueue.global(qos: .userInitiated).async { s.startRunning() }
    }
}

struct MirrorView: NSViewRepresentable {
    func makeNSView(context: Context) -> MirrorNSView {
        let v = MirrorNSView(frame: .zero)
        v.start()
        return v
    }
    func updateNSView(_ nsView: MirrorNSView, context: Context) {}
    static func dismantleNSView(_ nsView: MirrorNSView, coordinator: ()) { nsView.stop() }
}

struct NotchMirror: View {
    var body: some View {
        HStack(spacing: 16) {
            MirrorView()
                .frame(width: 150, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.15)))
            VStack(alignment: .leading, spacing: 6) {
                Text("Mirror").font(.system(size: 14, weight: .semibold))
                Text("A quick check before your next call. The camera turns off as soon as the notch closes.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}
