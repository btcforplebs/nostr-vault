import SwiftUI

// The Vault Dashboard's two detail pages, under Advanced. Pushed inside the
// dashboard sheet and built from its own sections and rows, so they read as
// part of it: no status header, no relay controls, no console. Those live
// once, on the dashboard itself. These replaced the old relay and Blossom
// dashboards, which carried their own copies of all three.

// MARK: - Relay details

/// Where the vault is and what it holds, by kind.
struct RelayDetailsPage: View {
    @EnvironmentObject var relayManager: RelayProcessManager
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var statsService: StatsService

    @State private var counts: [Int: Int] = [:]
    @State private var isCounting = false
    @State private var didCopyAddress = false
    @State private var showingBreakdown = false

    private var config: HavenConfig { configService.config }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                relaySection
                storedSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(Color.platformWindowBackground.ignoresSafeArea())
        .refreshable { await count() }
        .task(id: relayManager.isRunning) { await count() }
        .sheet(isPresented: $showingBreakdown) {
            EventKindBreakdownView()
                .environmentObject(statsService)
        }
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

    // MARK: What's stored

    /// Kinds grouped the way people think of them. Anything not named here
    /// (and every kind the count does not ask about) is "Other".
    private static let groups: [(title: String, icon: String, kinds: [Int])] = [
        ("Notes", VaultMode.notes.symbol, [1]),
        ("Articles", VaultMode.articles.symbol, [30023, 30024]),
        ("Reactions", VaultMode.likes.symbol, [7]),
        ("Reposts", "arrow.2.squarepath", [6, 16]),
        ("Zaps", VaultMode.zaps.symbol, [9734, 9735]),
        ("Messages", "envelope.fill", [4, 1059]),
        ("Profile and lists", "person.crop.circle",
         [0, 3, 10000, 10001, 10002, 10003, 10005, 10006, 10015, 10030, 30000, 30001, 30002]),
    ]

    /// The count's total, under key -1 (see `StatsService.fetchCountsByKind`).
    private var total: Int? { counts[-1] }

    private var groupRows: [(title: String, icon: String, count: Int)] {
        var rows: [(title: String, icon: String, count: Int)] = Self.groups.map { group in
            (group.title, group.icon, group.kinds.reduce(0) { $0 + (counts[$1] ?? 0) })
        }
        let named = rows.reduce(0) { $0 + $1.count }
        if let total, total > named {
            rows.append(("Other", "ellipsis.circle", total - named))
        }
        return rows.filter { $0.count > 0 }
    }

    private var storedSection: some View {
        DashboardSection(title: "What's stored", detail: total.map { $0.formatted() }) {
            if counts.isEmpty {
                HStack(spacing: 8) {
                    if isCounting { ProgressView().controlSize(.small) }
                    Text(isCounting ? "Counting…"
                         : relayManager.isRunning ? "Couldn't count. Pull down to try again."
                         : "Start your vault to count what's in it.")
                        .font(.appSystem(size: 13))
                        .foregroundColor(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            } else {
                let rows = groupRows
                ForEach(Array(rows.enumerated()), id: \.element.title) { index, row in
                    if index > 0 { DashboardDivider() }
                    Button { showingBreakdown = true } label: {
                        ValueRow(icon: row.icon, title: row.title, value: row.count.formatted(), chevron: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Shows every kind"))
                }
            }
        }
    }

    private func count() async {
        guard relayManager.isRunning else { return }
        isCounting = true
        let fresh = await statsService.fetchCountsByKind()
        // An incomplete answer comes back empty; keep what is shown.
        if !fresh.isEmpty { counts = fresh }
        isCounting = false
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
