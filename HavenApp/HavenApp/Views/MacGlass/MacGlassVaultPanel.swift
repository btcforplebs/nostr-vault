import SwiftUI

#if os(macOS)

/// The menu bar vault panel as the Mac app's home (spec §1.2): a status strip,
/// three glance tiles, then the actions. Glass is the status strip and the
/// buttons; the tiles are plain content.
///
/// Same rule as before: nothing here opens a sheet and nothing starts a data
/// load. The only read on open is `ActiveConnectionsC()`, a mutex and a len.
struct MacGlassVaultPanel: View {
    @ObservedObject var configService: ConfigService
    @ObservedObject var relayManager: RelayProcessManager
    @ObservedObject private var statsService = StatsService.shared
    @ObservedObject private var mesh = MacFipsMeshService.shared
    @ObservedObject private var outbox = MediaPostQueue.shared

    let onToggleRelay: () -> Void
    let onNewNote: () -> Void
    let onOpenApp: () -> Void
    let onSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusStrip
            if let job = MacVaultGlance.job(relayManager) {
                jobRow(job)
                    .transition(.opacity)
            }
            tiles
            actions
            footer
        }
        .padding(12)
        .frame(width: 340)
        .background(MacGlassBackdrop().opacity(0.9))
        .animation(Motion.fade, value: MacVaultGlance.job(relayManager))
        .onAppear { MacVaultGlance.refreshConnections(relayManager) }
    }

    // MARK: Zone 1: status strip

    private var statusStrip: some View {
        HStack(spacing: 12) {
            MacVaultArchMark(glow: MacVaultGlance.glow(relayManager), size: 28)

            VStack(alignment: .leading, spacing: 3) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(stateLine(now: context.date))
                        .font(.appSystem(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                }
                if let connections = MacVaultGlance.connections(relayManager) {
                    Text("\(connections) · port \(String(configService.config.relayPort))")
                        .font(.appSystem(size: 11))
                        .foregroundColor(.secondary)
                } else {
                    Text("Phones and the web can't reach it now")
                        .font(.appSystem(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            Spacer(minLength: 0)

            Circle()
                .fill(MacVaultGlance.stateTint(relayManager))
                .frame(width: 8, height: 8)
                .shadow(color: MacVaultGlance.stateTint(relayManager).opacity(0.8), radius: 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .macGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous), tint: Color.havenPurple.opacity(0.25))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Vault status")
    }

    private func stateLine(now: Date) -> String {
        let state = MacVaultGlance.stateLabel(relayManager)
        guard let up = MacVaultGlance.uptime(relayManager, now: now) else { return state }
        return "\(state) · \(up)"
    }

    private func jobRow(_ job: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(job)
                .font(.appSystem(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    // MARK: Zone 2: glance tiles

    private var tiles: some View {
        HStack(spacing: 8) {
            tile(title: "Stored", value: MacVaultGlance.stored(statsService), icon: "tray.full")
            tile(title: "Mesh", value: MacVaultGlance.mesh(mesh, config: configService.config), icon: "point.3.connected.trianglepath.dotted")
            if let waiting = MacVaultGlance.outbox(outbox) {
                tile(title: "Outbox", value: waiting, icon: "paperplane")
            }
        }
    }

    private func tile(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.appSystem(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .labelStyle(.titleAndIcon)
            Text(value)
                .font(.appSystem(size: 12, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
        .padding(10)
        .macContentTile()
        .accessibilityElement(children: .combine)
    }

    // MARK: Zone 3: actions

    private var actions: some View {
        MacGlassGroup(spacing: 8) {
            VStack(spacing: 8) {
                Button(action: onOpenApp) {
                    Label("Open Nostr Vault", systemImage: "macwindow")
                        .frame(maxWidth: .infinity)
                }
                .macGlassButton(prominent: true)
                .controlSize(.large)

                HStack(spacing: 8) {
                    // None for a read-only sign-in: it can't sign a note.
                    if configService.activeAccountCanSign {
                        Button(action: onNewNote) {
                            Label("New Note", systemImage: "square.and.pencil")
                                .frame(maxWidth: .infinity)
                        }
                        .macGlassButton()
                        .help("New Note (⌘N)")
                    }
                    Button(action: onToggleRelay) {
                        Label(
                            relayManager.isBooting ? "Starting…" : (relayManager.isRunning ? "Restart" : "Start"),
                            systemImage: relayManager.isRunning ? "arrow.clockwise" : "play.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .macGlassButton()
                    .disabled(relayManager.isBooting)
                }
                .controlSize(.regular)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            MacGlassAccountMenu(configService: configService)
            Spacer()
            iconButton("gearshape", help: "Settings (⌘,)", action: onSettings)
            iconButton("power", help: "Quit Nostr Vault", action: onQuit)
        }
        .padding(.horizontal, 4)
    }

    private func iconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.appSystem(size: 13))
                .foregroundColor(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Quit says what it stops (spec §1.2). An NSAlert, not a SwiftUI dialog:
/// the panel closes when it resigns key, and a dialog hosted by it would go too.
@MainActor
enum MacQuitConfirmation {
    static func confirmAndQuit() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Quit Nostr Vault?"
        alert.informativeText = "Quitting stops your vault. Phones and the web can't reach it until you open Nostr Vault again."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
    }
}

#endif
