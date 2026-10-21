import SwiftUI
import AppKit

/// Settings → Glide: share this Mac's mouse and keyboard with a Windows PC (or another Mac), or the reverse.
struct GlideSettings: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var glide = GlideController.shared
    @State private var hostDraft = ""
    @State private var accessibility = AXIsProcessTrusted()
    @State private var inputMonitoring = CGPreflightListenEventAccess()

    private var sharing: Bool { state.config.glideRole == "share" }

    var body: some View {
        Form {
            Section {
                Toggle("Share a mouse and keyboard with another computer", isOn: $state.config.glideEnabled)
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(nsColor: glide.status.color))
                        .frame(width: 8, height: 8)
                    Text(glide.status.text)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    if state.config.glideEnabled {
                        Button("Reconnect") {
                            refreshPermissions()
                            GlideController.shared.restart()
                        }
                        .controlSize(.small)
                    }
                }
            } header: {
                Text("Glide")
            } footer: {
                Text("Push the pointer off the edge of one screen and it carries on onto the other computer, keyboard included. Works with a Windows PC running Glide for Windows, or another Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Which computer has the mouse?") {
                Picker("Mouse and keyboard", selection: $state.config.glideRole) {
                    Text("This Mac").tag("share")
                    Text("The other computer").tag("receive")
                }
                .pickerStyle(.segmented)

                if sharing {
                    HStack {
                        TextField("Other computer's IP address", text: $hostDraft, prompt: Text("192.168.1.50"))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(commitHost)
                        Button("Connect", action: commitHost)
                            .disabled(hostDraft.trimmingCharacters(in: .whitespaces) == state.config.glideHost)
                    }
                    Picker("The other computer sits to the", selection: $state.config.glideEdge) {
                        Text("Left").tag("left")
                        Text("Right").tag("right")
                    }
                    .pickerStyle(.segmented)
                    LabeledSlider(title: "Pointer speed on the other computer", value: $state.config.glideSpeed,
                                  range: 0.5...2.0, format: "%.1f×")
                    LabeledContent("Bring the pointer back", value: "⌃⌥⌘G")
                } else {
                    LabeledContent("This Mac's IP address") {
                        HStack {
                            Text(glide.addresses.isEmpty ? "Not on a network" : glide.addresses.joined(separator: ", "))
                                .textSelection(.enabled)
                            if let ip = glide.addresses.first {
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(ip, forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.borderless)
                                .help("Copy")
                            }
                        }
                    }
                    Text("On the other computer, enter this address. The PC brings the pointer back with Ctrl+Alt+Shift+G.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("On the Windows PC") {
                Text(sharing
                     ? "Run Glide for Windows as the receiver:"
                     : "Run Glide for Windows as the sharer (use --edge left if this Mac is to the left of the PC's screen):")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                CommandRow(command: sharing
                           ? "glide.exe receive"
                           : "glide.exe share \(glide.addresses.first ?? "<this Mac's IP>") --edge right")
                Text("Ctrl and ⌘ are swapped automatically, so Ctrl+C on the PC keyboard is ⌘C on this Mac and ⌘C here is Ctrl+C there. To turn that off, add --no-swap on the PC.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Options") {
                Toggle("Show a note in the notch when the other computer connects or drops", isOn: $state.config.glideFlashes)
            }

            Section("Permissions") {
                PermissionRow(title: "Accessibility", detail: "To move the pointer and type on this Mac",
                              granted: accessibility) {
                    Paster.openSettings()
                }
                if sharing {
                    PermissionRow(title: "Input Monitoring", detail: "To pick up this Mac's mouse and keyboard and send them over",
                                  granted: inputMonitoring) {
                        CGRequestListenEventAccess()
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                    }
                }
                Text("Keystrokes cross your network unencrypted for now. Use Glide only on a network you trust.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            hostDraft = state.config.glideHost
            refreshPermissions()
            glide.refreshAddresses()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private func commitHost() {
        state.config.glideHost = hostDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func refreshPermissions() {
        accessibility = AXIsProcessTrusted()
        inputMonitoring = CGPreflightListenEventAccess()
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let open: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Open Settings", action: open).controlSize(.small)
            }
        }
    }
}

private struct CommandRow: View {
    let command: String

    var body: some View {
        HStack {
            Text(command)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
        }
    }
}
