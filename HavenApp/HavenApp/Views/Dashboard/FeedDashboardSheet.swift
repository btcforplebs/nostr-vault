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
        let macURL = configService.config.macRelayURL

        return Group {
            if !macURL.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("MAC RELAY SYNC")
                        .font(.appSystem(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.8))

                    VStack(spacing: 1) {
                        // Status row
                        SyncStatusRow(
                            icon: "desktopcomputer",
                            title: "Mac Relay",
                            statusText: MacRelaySyncService.shared.isSyncing ? "Syncing..." : (MacRelaySyncService.shared.syncStatus.isEmpty ? "Idle" : MacRelaySyncService.shared.syncStatus),
                            statusColor: MacRelaySyncService.shared.isSyncing ? Color.havenPurple : (MacRelaySyncService.shared.lastSyncDate != nil ? .green : .secondary),
                            lastDate: MacRelaySyncService.shared.lastSyncDate,
                            lastDateLabel: "Last sync"
                        )

                        // Action row
                        HStack(spacing: 12) {
                            Button {
                                MacRelaySyncService.shared.forceSync()
                            } label: {
                                HStack(spacing: 6) {
                                    if MacRelaySyncService.shared.isSyncing {
                                        ProgressView().controlSize(.small).tint(.white)
                                    } else {
                                        Image(systemName: "arrow.clockwise")
                                    }
                                    Text("Sync Now")
                                }
                                .font(.appSystem(size: 12, weight: .bold))
                                .padding(.vertical, 8)
                                .padding(.horizontal, 16)
                                .background(Color.havenPurple)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                            .disabled(MacRelaySyncService.shared.isSyncing)

                            Button {
                                MacRelaySyncService.shared.resetSync()
                            } label: {
                                Text("Reset")
                                    .font(.appSystem(size: 12, weight: .medium))
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 16)
                                    .background(Color.secondary.opacity(0.1))
                                    .foregroundColor(.secondary)
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)

                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.platformCardBackground)
                    }
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
