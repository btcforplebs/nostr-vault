import SwiftUI

#if os(macOS)

/// "Your space": the right-hand column the iPad (landscape) and the web app
/// both keep beside the page. On the Mac it leads with the vault, because the
/// Mac is the one that runs all day. Every number comes from `MacVaultGlance`,
/// so nothing here is invented and nothing walks the disk.
struct MacSpaceColumn: View {
    @ObservedObject var configService: ConfigService
    @ObservedObject var relayManager: RelayProcessManager
    @ObservedObject private var statsService = StatsService.shared
    @ObservedObject private var mesh = MacFipsMeshService.shared
    @ObservedObject private var outbox = MediaPostQueue.shared
    @ObservedObject private var feedService = FeedService.shared
    @Binding var selectedTab: MenuBarView.Tab
    @Binding var settingsPaneRequest: SettingsView.SettingsTab?

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Your space")
                .font(.appSystem(size: 15, weight: .bold))
                .foregroundColor(.primary)
                .padding(.horizontal, 6)
                .frame(height: 52)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    liveVault
                    devices
                    web
                }
                .padding(.bottom, 12)
            }
        }
        .frame(width: MacShellLayout.spaceWidth)
        .onAppear { MacVaultGlance.refreshConnections(relayManager) }
    }

    // MARK: Live Vault

    private var liveVault: some View {
        MacSpacePanel(title: "Live Vault", systemImage: "lock.rectangle.stack", action: ("Open", { selectedTab = .relay })) {
            HStack(spacing: 12) {
                MacVaultArchMark(glow: MacVaultGlance.glow(relayManager), size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(stateLine(now: context.date))
                            .font(.appSystem(size: 14, weight: .semibold))
                            .foregroundColor(.primary)
                    }
                    Text(MacVaultGlance.connections(relayManager) ?? "Phones and the web can't reach it now")
                        .font(.appSystem(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
                Circle()
                    .fill(MacVaultGlance.stateTint(relayManager))
                    .frame(width: 8, height: 8)
            }

            if let job = MacVaultGlance.job(relayManager) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(job).font(.appSystem(size: 11)).foregroundColor(.secondary).lineLimit(1)
                }
            }

            Button(action: copyAddress) {
                HStack(spacing: 8) {
                    Text(address)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.appSystem(size: 11, weight: .medium))
                        .foregroundColor(copied ? .havenOnline : .secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .macContentTile(cornerRadius: 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy your vault's address")
            .accessibilityLabel("Copy your vault's address")

            HStack(spacing: 8) {
                tile("Stored", MacVaultGlance.stored(statsService), icon: "tray.full")
                if let waiting = MacVaultGlance.outbox(outbox) {
                    tile("Outbox", waiting, icon: "paperplane")
                }
            }
        }
    }

    private var address: String { "ws://127.0.0.1:\(String(configService.config.relayPort))" }

    private func copyAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    private func stateLine(now: Date) -> String {
        let state = MacVaultGlance.stateLabel(relayManager)
        guard let up = MacVaultGlance.uptime(relayManager, now: now) else { return state }
        return "\(state) · \(up)"
    }

    private func tile(_ title: String, _ value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon)
                .font(.appSystem(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
            Text(value)
                .font(.appSystem(size: 12, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(10)
        .macContentTile(cornerRadius: 10)
        .accessibilityElement(children: .combine)
    }

    // MARK: My devices

    private var devices: some View {
        MacSpacePanel(title: "My devices", systemImage: "point.3.connected.trianglepath.dotted", action: ("Manage", openMesh)) {
            let list = configService.config.meshDevices
            if !mesh.enabled {
                line("Mesh is off. Turn it on to reach your vault from your other devices.")
            } else if list.isEmpty {
                line("No devices linked yet.")
            } else {
                let peers = Set(mesh.status?.peers ?? [])
                VStack(spacing: 8) {
                    ForEach(list) { device in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(peers.contains(device.npub) ? Color.havenOnline : Color.white.opacity(0.25))
                                .frame(width: 7, height: 7)
                            Text(device.displayName)
                                .font(.appSystem(size: 12, weight: .medium))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(peers.contains(device.npub) ? "In reach" : "Not in reach")
                                .font(.appSystem(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                Text(MacVaultGlance.mesh(mesh, config: configService.config))
                    .font(.appSystem(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func openMesh() {
        settingsPaneRequest = .fipsMesh
        selectedTab = .settings
    }

    // MARK: Web of Trust

    private var web: some View {
        MacSpacePanel(title: "Web of Trust", systemImage: "globe", action: ("Open", { selectedTab = .wot })) {
            let follows = feedService.followedPubkeys.count
            let trusted = feedService.feedTrustedPubkeys.count
            if follows == 0 {
                line("Follow people to build your web. Global shows only people your web reaches.")
            } else {
                HStack(spacing: 8) {
                    tile("Following", follows.formatted(.number), icon: "person.2")
                    tile("In your web", trusted > 0 ? trusted.formatted(.number) : "Not built yet", icon: "circle.hexagongrid")
                }
            }
        }
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(.appSystem(size: 12))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One "Your space" panel: the look the iPad's `SpacePanelCard` and the web's
/// space panels share. Radius 14, a plain dark fill, a thin accent line.
/// Content, so never glass.
struct MacSpacePanel<Content: View>: View {
    let title: String
    let systemImage: String
    var action: (title: String, run: () -> Void)?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.appSystem(size: 11, weight: .semibold))
                    .foregroundColor(.havenPurple)
                Text(title)
                    .font(.appSystem(size: 12, weight: .bold))
                    .foregroundColor(.primary)
                Spacer(minLength: 0)
                if let action {
                    Button(action.title, action: action.run)
                        .buttonStyle(.plain)
                        .font(.appSystem(size: 11, weight: .semibold))
                        .foregroundColor(.havenPurple)
                        .accessibilityLabel("\(action.title) \(title)")
                }
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.platformSecondaryGroupedBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.havenPurple.opacity(0.28), lineWidth: 1)
        )
    }
}

#endif
