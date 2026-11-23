#if os(iOS)
import SwiftUI

/// "Your desktop Vault" on a phone or iPad: what the desktop Vault's trust
/// ranking, distant posts and hand-off are doing, read over the mesh, and
/// how old that read is. Nothing when no desktop is in My Devices. The Mac
/// shows its own (`MacVaultStatusCard`); Android's twin is
/// `DesktopVaultStatusCard.kt`.
struct DesktopVaultStatusCard: View {
    @EnvironmentObject var configService: ConfigService
    @ObservedObject private var store = DesktopVaultStatusStore.shared
    @ObservedObject private var copies = MeshCopyV2Service.shared
    /// Its own card (the Vault dashboard); off inside a panel that has one.
    var framed = false

    private var devices: [MeshDevice] { FipsMeshDevices.current(configService.config) }
    private var desktop: MeshDevice? { DesktopVaultPick.desktop(devices, lastSync: copies.syncState.lastAt) }

    var body: some View {
        if let desktop {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                content(desktop, now: context.date)
            }
            .task(id: desktop.npub) {
                // On screen: read now, then every minute.
                store.show(peer: desktop.npub)
                while !Task.isCancelled {
                    await store.refresh()
                    try? await Task.sleep(for: .seconds(DesktopVaultStatusStore.every))
                }
            }
        }
    }

    private func content(_ desktop: MeshDevice, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "desktopcomputer")
                    .font(.appSystem(size: 13, weight: .semibold))
                    .foregroundColor(.accentText)
                Text("Your desktop Vault")
                    .font(.appSystem(size: 14, weight: .bold))
                Spacer(minLength: 0)
                if store.checking { ProgressView().controlSize(.small) }
            }
            line(desktop.displayName + " · " + age(now: now))
            if let status = store.status {
                Text(VaultStatusText.headline(status))
                    .font(.appSystem(size: 13, weight: .semibold))
                    .padding(.top, 2)
                if let hint = VaultStatusText.pausedHint(status) { line(hint) }
                if let a = status.account(configService.activeAccountHexPubkey) {
                    if let progress = VaultStatusText.progress(a) { line(progress) }
                    line(VaultStatusText.finished(a, now: now))
                    if let distant = VaultStatusText.distant(a, bar: bar) { line(distant) }
                    line(VaultStatusText.distantFetch(a, now: now))
                    ForEach(a.handoffs, id: \.device) { h in
                        HStack {
                            Text(DesktopVaultPick.handoffName(h, devices: devices, selfHex: selfHex))
                                .font(.appSystem(size: 12, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(VaultStatusText.handoff(h, now: now))
                                .font(.appSystem(size: 12))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(framed ? 14 : 0)
        .background {
            if framed {
                RoundedRectangle(cornerRadius: 12).fill(Color.platformCardBackground)
                RoundedRectangle(cornerRadius: 12).stroke(Color.platformCardBorder, lineWidth: 1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "Updated 3 min ago", or why there is nothing newer.
    private func age(now: Date) -> String {
        let reach: String? = switch store.lastError {
        case nil: nil
        case "not_paired": "not caught up with yet"
        case "not_found": "update it to see this"
        default: "out of reach"
        }
        guard store.fetchedAt > 0 else { return reach.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Checking…" }
        let updated = DesktopVaultPick.updated(store.fetchedAt, now: now)
        return reach.map { "\(updated), \($0) now" } ?? updated
    }

    private var bar: Double? {
        configService.config.discoveryBar.flatMap { (0...100).contains($0) ? $0.rounded() : nil }
    }

    private var selfHex: String? {
        FipsMeshService.shared.ownMeshNpub.flatMap { Bech32.decode($0)?.hexString }
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(.appSystem(size: 12))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
