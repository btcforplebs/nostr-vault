import SwiftUI

// The Vault Dashboard's two detail pages, under Advanced. Pushed inside the
// dashboard sheet and built from its own sections and rows, so they read as
// part of it: no status header, no relay controls, no console. Those live
// once, on the dashboard itself. These replaced the old relay and Blossom
// dashboards, which carried their own copies of all three.

// MARK: - Relay details

/// Where the vault is: its address, port and how long it has run. What it
/// holds is on the dashboard, under In your vault.
struct RelayDetailsPage: View {
    @EnvironmentObject var relayManager: RelayProcessManager
    @EnvironmentObject var configService: ConfigService

    @State private var didCopyAddress = false

    private var config: HavenConfig { configService.config }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                relaySection
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(Color.platformWindowBackground.ignoresSafeArea())
    }

    // MARK: Your relay

    private var relaySection: some View {
        DashboardSection(title: "Your relay") {
            Button(action: copyAddress) {
                HStack(spacing: 8) {
                    RowLabel(icon: "link", title: "Address")
                    Spacer(minLength: 8)
                    Text(didCopyAddress ? "Copied" : config.nostrURL)
                        .font(.appSystem(size: 13, design: didCopyAddress ? .default : .monospaced))
                        .foregroundColor(didCopyAddress ? .havenOnline : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: didCopyAddress ? "checkmark" : "doc.on.doc")
                        .font(.appSystem(size: 11, weight: .semibold))
                        .foregroundColor(didCopyAddress ? .havenOnline : .secondary.opacity(0.6))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Address"))
            .accessibilityValue(Text(didCopyAddress ? "Copied" : config.nostrURL))
            .accessibilityHint(Text("Copies the address"))
            DashboardDivider()
            ValueRow(icon: "number", title: "Port", value: "\(config.relayPort)")
            DashboardDivider()
            TimelineView(.periodic(from: .now, by: 30)) { context in
                ValueRow(icon: "clock", title: "Running for", value: uptime(now: context.date))
            }
        }
    }

    private func uptime(now: Date) -> String {
        guard relayManager.isRunning, let start = relayManager.startDate else {
            return relayManager.isBooting ? "Starting…" : "Not running"
        }
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let days = seconds / 86_400, hours = (seconds % 86_400) / 3_600, minutes = (seconds % 3_600) / 60
        return days > 0 ? "\(days)d \(hours)h" : hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    private func copyAddress() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(config.nostrURL, forType: .string)
        #else
        UIPasteboard.general.string = config.nostrURL
        #endif
        withAnimation(Motion.control) { didCopyAddress = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation(Motion.control) { didCopyAddress = false }
        }
    }
}

/// A label and a value on one line, the shape of the dashboard's setting rows.
struct ValueRow: View {
    let icon: String
    let title: String
    let value: String
    var chevron = false

    var body: some View {
        HStack(spacing: 8) {
            RowLabel(icon: icon, title: title)
            Spacer(minLength: 8)
            Text(value)
                .font(.appSystem(size: 15))
                .foregroundColor(.secondary)
                .monospacedDigit()
                .lineLimit(1)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.appSystem(size: 12, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.6))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
