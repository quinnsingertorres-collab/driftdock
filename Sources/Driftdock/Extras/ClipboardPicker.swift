import SwiftUI
import AppKit

/// ⇧⌘V clipboard history picker. Choosing an item copies it, and pastes it too
/// when "Paste after choosing" is on and Accessibility access is granted.
final class ClipboardPickerController {
    static let shared = ClipboardPickerController()
    private var panel: KeyPanel?

    func toggle() {
        if let panel, panel.isVisible { panel.dismiss(); return }
        let panel = self.panel ?? KeyPanel(size: NSSize(width: 480, height: 460))
        self.panel = panel
        panel.contentView = NSHostingView(rootView: ClipboardPickerView(
            choose: { [weak panel] item in
                ClipboardModel.shared.copy(item)
                panel?.dismiss()
                if AppState.shared.config.clipboardAutoPaste { Paster.pasteSoon() }
            },
            close: { [weak panel] in panel?.dismiss() }
        ).environmentObject(AppState.shared))
        panel.present()
    }
}

enum Paster {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    private static var promptedThisLaunch = false

    /// Shows the system prompt that sends you to Accessibility settings — at most once
    /// per launch, and never when access is already granted. Pass `force` for a button
    /// the person clicked on purpose.
    static func requestAccess(force: Bool = false) {
        guard !isTrusted, force || !promptedThisLaunch else { return }
        promptedThisLaunch = true
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Opens System Settings → Privacy & Security → Accessibility.
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Sends ⌘V to whatever app has focus, once focus has settled back on it.
    static func pasteSoon() {
        guard isTrusted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let src = CGEventSource(stateID: .combinedSessionState)
            let vKey: CGKeyCode = 9
            let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
            let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }
}

struct ClipboardPickerView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var model = ClipboardModel.shared
    let choose: (ClipItem) -> Void
    let close: () -> Void
    @State private var filter = ""
    @State private var selection = 0
    @State private var renaming: UUID?
    @State private var renameText = ""
    @FocusState private var focused: Bool

    private var items: [ClipItem] {
        let f = filter.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return model.items }
        return model.items.filter { $0.displayText.localizedCaseInsensitiveContains(f) || $0.text.localizedCaseInsensitiveContains(f) }
    }

    var body: some View {
        let list = items
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard").foregroundStyle(state.accent)
                TextField("Search clipboard history", text: $filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($focused)
                    .onSubmit { if list.indices.contains(selection) { choose(list[selection]) } }
                    .onChange(of: filter) { _, _ in selection = 0 }
                if !model.items.isEmpty {
                    Button("Clear") { model.clearUnpinned() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .help("Clear everything except pinned items")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            Divider().opacity(0.4)
            if list.isEmpty {
                Spacer()
                Text(model.items.isEmpty ? "Copy some text or an image and it shows up here." : "No matches.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, item in
                            row(item, selected: i == selection)
                                .onTapGesture { choose(item) }
                                .onDrag { model.dragProvider(for: item) }
                        }
                    }
                    .padding(8)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: list.map(\.id))
                }
            }
            HStack {
                Text(state.config.clipboardAutoPaste && Paster.isTrusted ? "Return pastes" : "Return copies")
                Spacer()
                Text("Drag any item out · ↑↓ · Esc")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(height: 30)
        }
        .frame(width: 480, height: 460)
        .background(VisualEffect(material: .hudWindow, dark: true, radius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
        .onKeyPress(.downArrow) { selection = min(selection + 1, max(list.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .onAppear {
            filter = ""
            selection = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
        }
    }

    @ViewBuilder
    private func row(_ item: ClipItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            if item.kind == .image, let image = item.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 54, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            if renaming == item.id {
                TextField("Name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        model.rename(item, to: renameText)
                        renaming = nil
                    }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.displayText)
                        .lineLimit(2)
                        .font(.system(size: 13, weight: item.title == nil ? .regular : .semibold))
                    if item.title != nil && item.kind == .text {
                        Text(item.text.replacingOccurrences(of: "\n", with: " "))
                            .lineLimit(1)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 2) {
                if item.kind == .image {
                    glassButton("text.viewfinder", help: "Copy text from image (OCR)") { model.copyText(from: item) }
                }
                glassButton("pencil", help: "Rename") {
                    renameText = item.title ?? ""
                    renaming = item.id
                }
                glassButton(item.pinned ? "pin.fill" : "pin", on: item.pinned, help: item.pinned ? "Unpin" : "Pin to the top") {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { model.togglePin(item) }
                }
                glassButton("xmark", help: "Remove") {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.remove(item) }
                }
            }
            .opacity(selected || item.pinned ? 1 : 0.55)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(selected ? state.accent.opacity(0.35) : Color.white.opacity(item.pinned ? 0.07 : 0)))
        .contentShape(Rectangle())
    }

    /// Small circular glass buttons like Droppy's clipboard action bar.
    private func glassButton(_ symbol: String, on: Bool = false, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 24, height: 24)
                .background(Circle().fill(on ? state.accent.opacity(0.7) : Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
