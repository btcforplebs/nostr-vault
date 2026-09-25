import SwiftUI

// MARK: - Feed Dashboard Sheet

struct FeedDashboardSheet: View {
    @Environment(\.dismiss) var dismiss
    var onDismiss: (() -> Void)? = nil
    @EnvironmentObject var relayManager: RelayProcessManager
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    @ObservedObject private var feedService = FeedService.shared
    #if os(iOS)
    @State private var showFeedRelaySettings = false
    #endif

    var body: some View {
        #if os(iOS)
        NavigationStack {
            sheetContent
                .navigationTitle("Feed Dashboard")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") { performDismiss() }
                            .fontWeight(.semibold)
                    }
                }
                .navigationDestination(isPresented: $showFeedRelaySettings) {
                    FeedSettingsView()
                        .environmentObject(configService)
                        .navigationTitle("Feed Relays")
                        .navigationBarTitleDisplayMode(.inline)
                }
        }
        #else
        VStack(spacing: 0) {
            // macOS header with dismiss
            HStack {
                Text("Feed Dashboard")
                    .font(.appSystem(size: 16, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: { performDismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.appSystem(size: 16))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            sheetContent
        }
        .frame(minWidth: 460, minHeight: 600)
        #endif
    }

    private var sheetContent: some View {
        ScrollView {
            VStack(spacing: 20) {
                contentFilters

                blockedUsersSummary

                feedRelaysSection

                #if os(iOS)
                macRelaySyncSection
                #endif

                quickActions
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color.platformWindowBackground.ignoresSafeArea())
    }

    // MARK: - Content Filters

    private var contentFilters: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CONTENT FILTERS")
                .font(.appSystem(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.8))

            VStack(spacing: 1) {
                FilterToggleRow(
                    icon: "arrow.2.squarepath",
                    title: "Show Reposts",
                    subtitle: "Include reposted notes in your feed",
                    isOn: Binding(
                        get: { configService.config.showReposts },
                        set: { newValue in
                            configService.config.showReposts = newValue
                            configService.save()
                            feedService.recomputeFilteredNotes()
                        }
                    )
                )

                FilterToggleRow(
                    icon: "message.fill",
                    title: "Show Replies",
                    subtitle: "Include reply threads in your feed",
                    isOn: Binding(
                        get: { configService.config.showReplies },
                        set: { newValue in
                            configService.config.showReplies = newValue
                            configService.save()
                            feedService.recomputeFilteredNotes()
                        }
                    )
                )

                FilterToggleRow(
                    icon: "bolt.circle.fill",
                    title: "Auto-Load New Posts",
                    subtitle: "Automatically show new posts as they arrive",
                    isOn: Binding(
                        get: { configService.config.autoLoadNewPosts },
                        set: { newValue in
                            configService.config.autoLoadNewPosts = newValue
                            configService.save()
                        }
                    )
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Blocked Users Summary

    private var blockedUsersSummary: some View {
        let blockedCount = configService.activeAccountBlockedHexPubkeys.count
        let blacklistCount = configService.config.blacklistedNpubs.count

        return VStack(alignment: .leading, spacing: 8) {
            Text("NOISE FILTERING")
                .font(.appSystem(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.8))

            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "person.slash.fill")
                        .font(.appSystem(size: 14))
                        .foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(blockedCount)")
                            .font(.appSystem(size: 16, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                        Text("Blocked")
                            .font(.appSystem(size: 10))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    Image(systemName: "xmark.shield.fill")
                        .font(.appSystem(size: 14))
                        .foregroundColor(.red.opacity(0.8))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(blacklistCount)")
                            .font(.appSystem(size: 16, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                        Text("Blacklisted")
                            .font(.appSystem(size: 10))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    Image(systemName: "shield.checkered")
                        .font(.appSystem(size: 14))
                        .foregroundColor(.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Active")
                            .font(.appSystem(size: 16, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                        Text("Spam Filter")
                            .font(.appSystem(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(12)
            .background(Color.platformCardBackground)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )

            Text("Blocked users' content is hidden from your feed. Spam and noise are filtered automatically.")
                .font(.appSystem(size: 10, weight: .medium))
                .foregroundColor(.secondary.opacity(0.5))
                .italic()
        }
    }

    // MARK: - Feed Relays

    private var feedRelaysSection: some View {
        let isLive = feedService.connectionStatus == "Live"

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("FEED RELAYS")
                    .font(.appSystem(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.8))
                Spacer()
                HStack(spacing: 4) {
                    Text("Edit")
                        .font(.appSystem(size: 10, weight: .medium))
                        .foregroundColor(Color.havenPurple)
                    Image(systemName: "chevron.right")
                        .font(.appSystem(size: 8, weight: .semibold))
                        .foregroundColor(Color.havenPurple.opacity(0.7))
                }
            }

            VStack(spacing: 1) {
                // Local relay row
                FeedRelayRow(
                    url: "Nostr Vault (Local)",
                    isConnected: relayManager.isRunning,
                    isBooting: relayManager.isBooting,
                    isLocal: true
                )

                // External relays
                ForEach(configService.config.feedRelays, id: \.self) { relay in
                    FeedRelayRow(
                        url: relay,
                        isConnected: isLive,
                        isBooting: false,
                        isLocal: false
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            navigateToFeedRelaySettings()
        }
    }

    private func navigateToFeedRelaySettings() {
        #if os(iOS)
        showFeedRelaySettings = true
        #else
        performDismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NotificationCenter.default.post(name: .havenOpenFeedRelaySettings, object: nil)
        }
        #endif
    }

    // MARK: - Mac Relay Sync (iOS only)

    #if os(iOS)
    private var macRelaySyncSection: some View {
        Group {
            if !configService.config.macRelayURL.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("MAC RELAY SYNC")
                        .font(.appSystem(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.8))

                    MacRelaySyncStatusView()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.platformCardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
    #endif

    // MARK: - Quick Actions

    private var quickActions: some View {
        let columns = [
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible())
        ]

        return VStack(alignment: .leading, spacing: 8) {
            Text("ACTIONS")
                .font(.appSystem(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.8))

            LazyVGrid(columns: columns, spacing: 10) {
                ActionButton(
                    icon: "arrow.clockwise",
                    title: "Refresh",
                    isLoading: feedService.isLoadingFeed,
                    action: { feedService.refresh() }
                )
                ActionButton(
                    icon: "arrow.counterclockwise",
                    title: "Reload",
                    action: {
                        feedService.forceReload()
                        feedService.refresh()
                    }
                )
                ActionButton(
                    icon: "tray.and.arrow.down",
                    title: "Load \(feedService.pendingNotes.count)",
                    action: { feedService.applyPendingNotes() }
                )
            }
        }
    }

    // MARK: - Dismiss

    private func performDismiss() {
        if let onDismiss = onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }
}

// MARK: - Filter Toggle Row

private struct FilterToggleRow: View {
    let icon: String
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.appSystem(size: 15, weight: .medium))
                .foregroundColor(isOn ? Color.havenPurple : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.appSystem(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.appSystem(size: 10))
                    .foregroundColor(.secondary.opacity(0.7))
                    .lineLimit(1)
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(Color.havenPurple)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.platformCardBackground)
        .overlay(
            Rectangle()
                .fill(Color.white.opacity(0.03))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }
}

// MARK: - Feed Relay Row

private struct FeedRelayRow: View {
    let url: String
    let isConnected: Bool
    let isBooting: Bool
    let isLocal: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isBooting ? Color.yellow : (isConnected ? Color.green : Color.red.opacity(0.7)))
                .frame(width: 6, height: 6)

            if isLocal {
                Image(systemName: "server.rack")
                    .font(.appSystem(size: 12))
                    .foregroundColor(Color.havenPurple)
                    .frame(width: 16)
            }

            Text(url)
                .font(.appSystem(size: 11, weight: isLocal ? .semibold : .regular, design: .monospaced))
                .foregroundColor(isLocal ? .white : .secondary.opacity(0.8))
                .lineLimit(1)

            Spacer()

            Text(isBooting ? "Booting" : (isConnected ? "Connected" : "Offline"))
                .font(.appSystem(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(isBooting ? .yellow : (isConnected ? .green.opacity(0.7) : .red.opacity(0.5)))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.platformCardBackground)
        .overlay(
            Rectangle()
                .fill(Color.white.opacity(0.03))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }
}

// MARK: - Sync Status Row

private struct SyncStatusRow: View {
    let icon: String
    let title: String
    let statusText: String
    let statusColor: Color
    var lastDate: Date? = nil
    var lastDateLabel: String = "Last run"

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.appSystem(size: 14, weight: .medium))
                .foregroundColor(Color.havenPurple)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.appSystem(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                if let date = lastDate {
                    Text("\(lastDateLabel): \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.appSystem(size: 10))
                        .foregroundColor(.secondary.opacity(0.7))
                        .lineLimit(1)
                }
            }

            Spacer()

            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(statusText)
                    .font(.appSystem(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.8))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.platformCardBackground)
        .overlay(
            Rectangle()
                .fill(Color.white.opacity(0.03))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }
}

#if os(iOS)
/// State of the Mac relay copy. Syncing with the Mac is done by the embedded
/// relay itself (the Mac is one of its relays); this shows the one-time
/// full-history copy and its missing-events check, and re-runs them on demand.
struct MacRelaySyncStatusView: View {
    @EnvironmentObject var configService: ConfigService
    @ObservedObject private var relayManager = RelayProcessManager.shared
    @State private var status: RelayConfiguration.MacSyncStatus?
    @State private var checkRequested = false

    private var configuredMac: String {
        RelayConfiguration.macRelayURL(config: configService.config)
    }

    /// The relay reads the Mac address only when it starts, so a new address
    /// does nothing — and a check would run against the old one — until the
    /// relay is restarted.
    private var needsRestart: Bool {
        guard relayManager.isRunning, let running = relayManager.lastConfig else { return false }
        return RelayConfiguration.macRelayURL(config: running) != configuredMac
    }

    private var isForCurrentMac: Bool {
        status?.macURL == configuredMac
    }

    /// A copy refreshes its heartbeat every 20s; one silent for 90s died with
    /// its relay and is retried on the next start.
    private var isStale: Bool {
        guard let beat = status?.updatedAt ?? status?.startedAt else { return true }
        return Date().timeIntervalSince1970 - TimeInterval(beat) > 90
    }

    private var isRunning: Bool {
        isForCurrentMac && status?.state == "running" && !isStale
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if isRunning || checkRequested {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: icon).foregroundColor(iconColor)
                }
                Text(headline)
                    .font(.appSystem(size: 13, weight: .semibold))
            }
            if let detail {
                Text(detail)
                    .font(.appCaption)
                    .foregroundColor(.secondary)
            }
            Button {
                checkRequested = true
                RequestMacSyncCheckC()
            } label: {
                Label("Check sync with Mac", systemImage: "arrow.triangle.2.circlepath")
                    .font(.appSystem(size: 12, weight: .bold))
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.havenPurple)
            .disabled(isRunning || checkRequested || needsRestart || !relayManager.isRunning)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            // The copy runs inside the relay; poll its status file while visible.
            var requestedAt: Date?
            while !Task.isCancelled {
                let latest = RelayConfiguration.macSyncStatus(under: ConfigService.shared.relayDataDir)
                if checkRequested {
                    requestedAt = requestedAt ?? Date()
                    let pickedUp = latest?.state == "running" || (latest?.startedAt ?? 0) > (status?.startedAt ?? 0)
                    // Never spin forever: a request the relay didn't take
                    // (not running yet, or already mid-copy) clears itself.
                    if pickedUp || Date().timeIntervalSince(requestedAt!) > 30 {
                        checkRequested = false
                        requestedAt = nil
                    }
                }
                status = latest
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private var icon: String {
        guard isForCurrentMac, let state = status?.state else { return "clock" }
        switch state {
        case "done": return "checkmark.circle.fill"
        case "incomplete": return "exclamationmark.triangle.fill"
        case "failed": return "xmark.octagon.fill"
        default: return "clock"
        }
    }

    private var iconColor: Color {
        guard isForCurrentMac else { return .secondary }
        switch status?.state {
        case "done": return .havenOnline
        case "incomplete": return .orange
        case "failed": return .red
        default: return .secondary
        }
    }

    private var headline: String {
        if needsRestart { return "Restart the relay to use this Mac address" }
        if checkRequested { return "Checking with your Mac…" }
        guard isForCurrentMac, let status, let state = status.state else {
            return "Full copy from your Mac hasn't run yet"
        }
        switch state {
        case "running":
            return isStale ? "Copy was interrupted" : "Copying your full history from the Mac…"
        case "done":
            return (status.missing ?? 0) < 0 ? "Copied (this Mac can't be checked)" : "Everything copied · 0 missing"
        case "incomplete":
            let missing = status.missing ?? 0
            return missing > 0 ? "\(missing) still missing" : "Copy didn't finish"
        case "failed": return "Couldn't copy from your Mac"
        default: return state
        }
    }

    private var detail: String? {
        guard isForCurrentMac, let status else {
            return "It starts on its own shortly after the relay starts. After that, new posts and mentions keep syncing on their own."
        }
        if status.state == "running" {
            return isStale ? "The app closed during the copy. It picks up again next time the relay starts." : nil
        }
        var parts: [String] = []
        parts.append("\(status.posts ?? 0) posts and \(status.mentions ?? 0) mentions copied.")
        if let finished = status.finishedAt {
            let date = Date(timeIntervalSince1970: TimeInterval(finished))
            parts.append("Checked \(date.formatted(date: .abbreviated, time: .shortened)).")
        }
        if status.state == "incomplete" || status.state == "failed" {
            if let error = status.error, !error.isEmpty { parts.append(error) }
            parts.append("It tries again next time the app starts.")
        }
        if (status.missing ?? 0) < 0 {
            parts.append("Your Mac's relay is too old to compare lists, so it was copied page by page.")
        }
        return parts.joined(separator: " ")
    }
}
#endif
