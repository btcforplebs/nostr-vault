import SwiftUI

#if os(macOS)

/// What this Mac's desktop Vault is doing: the trust ranking (running,
/// paused or idle, its ring and lists while it runs, the last finish and its
/// counts), the distant posts fetch, and when each paired device last took
/// the ranking. Shown in the menu bar panel (`compact`) and in Your space.
/// Every line comes from the engine's status read (`VaultStatusStore`).
struct MacVaultStatusCard: View {
    @ObservedObject var configService: ConfigService
    @ObservedObject private var store = VaultStatusStore.shared
    /// The menu bar's short form: the state, its progress or last finish,
    /// and the distant count. Your space adds the distant fetch and devices.
    var compact = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .onAppear { store.watch() }
        .onDisappear { store.unwatch() }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if let status = store.status {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    stateIcon(status)
                    Text(VaultStatusText.headline(status))
                        .font(.appSystem(size: compact ? 12 : 13, weight: .semibold))
                        .foregroundColor(.primary)
                    Spacer(minLength: 0)
                }
                if let hint = VaultStatusText.pausedHint(status), !compact || status.accounts.isEmpty {
                    small(hint)
                }
                if let a = status.account(configService.activeAccountHexPubkey) {
                    if let progress = VaultStatusText.progress(a) { small(progress) }
                    small(VaultStatusText.finished(a, now: now))
                    if let distant = VaultStatusText.distant(a, bar: bar) { small(distant) }
                    if !compact {
                        small(VaultStatusText.distantFetch(a, now: now))
                        handoffs(a, now: now)
                    }
                } else if status.state != "off" {
                    small("No account to rank yet")
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Trust ranking status")
        } else {
            small("Reading the vault's status…")
        }
    }

    /// The bar the Discovery reach slider uses (Settings › Feeds), else the file's.
    private var bar: Double? {
        configService.config.discoveryBar.flatMap { (0...100).contains($0) ? $0.rounded() : nil }
    }

    private func stateIcon(_ s: VaultStatus) -> some View {
        Group {
            if s.state == "running" {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: s.state == "paused" ? "pause.circle" : "checkmark.circle")
                    .font(.appSystem(size: 12, weight: .semibold))
                    .foregroundColor(s.state == "paused" ? .secondary : .havenOnline)
            }
        }
        .frame(width: 16, height: 16)
    }

    @ViewBuilder
    private func handoffs(_ a: VaultStatus.Account, now: Date) -> some View {
        let devices = configService.config.meshDevices
        if a.handoffs.isEmpty {
            small(devices.isEmpty ? "No devices linked to take the ranking" : "No device has taken the ranking yet")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(a.handoffs, id: \.device) { h in
                    HStack(spacing: 6) {
                        Image(systemName: h.role.flatMap { MeshDeviceRole(rawValue: $0)?.icon } ?? "iphone")
                            .font(.appSystem(size: 10))
                            .foregroundColor(.secondary)
                        Text(DesktopVaultPick.handoffName(h, devices: devices, selfHex: nil))
                            .font(.appSystem(size: 11, weight: .medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(VaultStatusText.handoff(h, now: now))
                            .font(.appSystem(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    private func small(_ text: String) -> some View {
        Text(text)
            .font(.appSystem(size: 11))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#endif
