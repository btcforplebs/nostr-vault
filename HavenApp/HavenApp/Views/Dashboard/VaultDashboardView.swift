import SwiftUI

/// The Vault Dashboard (v2): one page that answers four questions about the
/// vault, in order. Is it running? Is it safe? Who can reach me? Is it
/// complete? Relay internals, mirrors and raw logs sit under Advanced.
///
/// Replaces the relay dashboard with Blossom's sections stacked under it,
/// which had two Statistics sections, two Actions sections, two activity logs
/// and a Storage Overview repeating the tiles.
struct VaultDashboardView: View {
    @EnvironmentObject var relayManager: RelayProcessManager
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var statsService: StatsService
    @ObservedObject private var mirrorService = MirrorService.shared
    @ObservedObject private var followingBackup = FollowingBackupService.shared
    @ObservedObject private var feedService = FeedService.shared
    @StateObject private var exporter = VaultExporter()
    @Environment(\.dismiss) private var dismiss

    @State private var kindCounts: [Int: Int] = [:]
    @State private var mediaCount: Int?
    @State private var macSync: RelayConfiguration.MacSyncStatus?
    @State private var isPreparingImport = false
    @State private var didCopyAddress = false
    @State private var haloPulse = false
    @State private var showingStorageBreakdown = false
    @State private var showingFullActivity = false
    @State private var showingShareSheet = false
    /// Bumped when a "last ran" date changes, since `VaultHistory` lives in
    /// UserDefaults and nothing observes it.
    @State private var historyRevision = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                statusCard
                safetySection
                reachSection
                ownedSection
                storageSection
                keepItFullSection
                settingsSection
                activitySection
                advancedSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(Color.platformWindowBackground.ignoresSafeArea())
        .refreshable {
            // A light top-up, never a full import (see DashboardView).
            if relayManager.isRunning && !relayManager.isImporting { RequestRelaySyncC() }
            await refresh()
        }
        .task { await refresh() }
        .onChange(of: relayManager.isRunning) { _, running in
            if running { Task { await refresh() } }
        }
        .onChange(of: relayManager.importCompleted) { _, completed in
            if completed { isPreparingImport = false; historyRevision += 1 }
        }
        .onChange(of: relayManager.isImporting) { _, importing in
            if importing { isPreparingImport = false }
        }
        .onChange(of: mirrorService.lastMirrorDate) { _, _ in historyRevision += 1 }
        .onChange(of: exporter.running == nil) { _, _ in historyRevision += 1 }
        .onChange(of: exporter.shareURL) { _, url in showingShareSheet = url != nil }
        // The Pocket Relay tutorial starts the first time the dashboard opens.
        .task(id: TutorialCenter.shared.revision) {
            TutorialCenter.shared.startIfEligible(.pocketRelay, account: NostrService.shared.activeHexPubkey)
        }
        #if os(iOS)
        .sheet(isPresented: $showingShareSheet, onDismiss: { exporter.shareURL = nil }) {
            if let url = exporter.shareURL {
                ShareSheet(activityItems: [url])
            }
        }
        #endif
        .sheet(isPresented: $showingStorageBreakdown) {
            StorageBreakdownView()
                .environmentObject(statsService)
                .environmentObject(configService)
        }
        .sheet(isPresented: $showingFullActivity) {
            NavigationStack {
                RelayActivityWindow(logStore: relayManager.logStore) {
                    showingFullActivity = false
                }
                .environmentObject(relayManager)
                .environmentObject(configService)
            }
        }
    }

    private var config: HavenConfig { configService.config }

    private func refresh() async {
        statsService.refreshStats()
        macSync = RelayConfiguration.macSyncStatus(under: configService.relayDataDir)
        guard relayManager.isRunning else { return }
        let counts = await statsService.fetchCountsByKind()
        if !counts.isEmpty { kindCounts = counts }
        let owner = nostrService.activeHexPubkey
        if !owner.isEmpty {
            mediaCount = await statsService.fetchBlobList(for: owner).count
        }
    }

    // MARK: - Status

    private enum RunState {
        case running, syncing, starting, paused, needsFix
    }

    private var runState: RunState {
        if relayManager.isLocked || relayManager.isPortConflict { return .needsFix }
        if relayManager.isBooting { return .starting }
        guard relayManager.isRunning else { return .paused }
        return relayManager.isWotSyncing ? .syncing : .running
    }

    private var statusColor: Color {
        switch runState {
        case .running: return .havenOnline
        case .syncing, .starting: return .orange
        case .paused, .needsFix: return .orange
        }
    }

    private var statusTitle: String {
        switch runState {
        case .running, .syncing: return "Your vault is running"
        case .starting: return "Your vault is starting…"
        case .paused: return "Your vault is paused"
        case .needsFix: return "Your vault needs a restart"
        }
    }

    /// Plain words for what is wrong and what the one button does.
    private var problemText: String? {
        switch runState {
        case .paused:
            return "It isn't saving new notes or messages. Start it to catch up."
        case .needsFix:
            return relayManager.isPortConflict
                ? "Another app is using port \(config.relayPort). Restarting clears it."
                : "The last session didn't shut down cleanly. Restarting clears the lock."
        default:
            return nil
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                statusDot

                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle)
                        .font(.appSystem(size: 17, weight: .bold))
                        .foregroundColor(.primary)
                    statusSubtitle
                    addressButton
                }
                .accessibilityElement(children: .contain)

                Spacer(minLength: 8)

                statusMenu
            }

            if let problemText {
                Text(problemText)
                    .font(.appSystem(size: 13))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: fixRelay) {
                    Text(runState == .paused ? "Start vault" : "Restart vault")
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                        .background(Color.havenPurple, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(problemText == nil ? Color.platformCardBackground : Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(problemText == nil ? Color.platformCardBorder : Color.orange.opacity(0.35), lineWidth: 1)
        )
        .animation(Motion.toggle, value: problemText == nil)
        .tutorialAnchor(TutorialContent.relayStatus)
    }

    /// The halo pulses through a value-scoped animation on the halo alone, so
    /// the sheet's own controls never inherit the repeating transaction (the
    /// cause of the old dashboard's pulsing Done button).
    private var statusDot: some View {
        let pulses = runState == .running || runState == .syncing || runState == .starting
        return ZStack {
            Circle()
                .fill(statusColor.opacity(0.18))
                .frame(width: 28, height: 28)
                .scaleEffect(pulses && haloPulse ? 1.25 : 1.0)
                .animation(pulses ? Motion.ambientPulse : nil, value: haloPulse)
            Circle()
                .fill(statusColor)
                .frame(width: 12, height: 12)
        }
        .frame(width: 32, height: 32)
        .onAppear { haloPulse = true }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var statusSubtitle: some View {
        switch runState {
        case .starting:
            if !relayManager.bootStatusMessage.isEmpty {
                Text(relayManager.bootStatusMessage)
                    .font(.appSystem(size: 13))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        case .syncing:
            Text("Updating who can reach you…")
                .font(.appSystem(size: 13))
                .foregroundColor(.secondary)
        case .running:
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(uptimeLine(now: context.date))
                    .font(.appSystem(size: 13))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        case .paused, .needsFix:
            EmptyView()
        }
    }

    private func uptimeLine(now: Date) -> String {
        var parts: [String] = []
        if let start = relayManager.startDate {
            let seconds = max(0, Int(now.timeIntervalSince(start)))
            let days = seconds / 86_400, hours = (seconds % 86_400) / 3_600, minutes = (seconds % 3_600) / 60
            let up = days > 0 ? "\(days)d \(hours)h" : hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
            parts.append("Up \(up)")
        }
        let count = relayManager.activeConnections
        parts.append(count == 1 ? "1 connection" : "\(count) connections")
        return parts.joined(separator: " · ")
    }

    private var addressButton: some View {
        Button(action: copyAddress) {
            HStack(spacing: 5) {
                Text(config.nostrURL)
                    .font(.appSystem(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: didCopyAddress ? "checkmark" : "doc.on.doc")
                    .font(.appSystem(size: 9, weight: .semibold))
                    .foregroundColor(didCopyAddress ? .havenOnline : nil)
            }
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Vault address"))
        .accessibilityValue(Text(config.nostrURL))
        .accessibilityHint(Text("Copies the address"))
        .tutorialAnchor(TutorialContent.relayAddress)
    }

    private var statusMenu: some View {
        Menu {
            Button(action: copyAddress) {
                Label("Copy Address", systemImage: "doc.on.doc")
            }
            if relayManager.isRunning {
                Button {
                    relayManager.stopRelay { relayManager.startRelay(config: config) }
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
                Button(role: .destructive) {
                    relayManager.stopRelay()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
            } else if !relayManager.isBooting {
                Button {
                    relayManager.startRelay(config: config)
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.appSystem(size: 15, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 36, height: 36)
                .background(Color.platformControlBackground, in: Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .disabled(relayManager.isBooting)
        .accessibilityLabel("Vault controls")
    }

    private func fixRelay() {
        if runState == .needsFix {
            relayManager.forceCleanAndRestart()
        } else {
            relayManager.startRelay(config: config)
        }
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

    // MARK: - Is it safe?

    private var activeNpub: String {
        let active = config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        return active.isEmpty ? config.ownerNpub : active
    }

    private var hasLocalKey: Bool {
        activeNpub == config.ownerNpub ? !config.ownerNcryptsec.isEmpty : configService.hasCredential(forNpub: activeNpub)
    }

    private var usesSigner: Bool { config.activeSigningMode() == "nip46" && configService.hasBunkerConfig(forNpub: activeNpub) }

    private var safetyDoneCount: Int {
        [hasLocalKey || usesSigner, !followingBackup.snapshots.isEmpty, !config.macRelayURL.isEmpty, VaultHistory.lastNotesBackup != nil]
            .filter { $0 }.count
    }

    private var safetySection: some View {
        let _ = historyRevision
        return DashboardSection(title: "Is it safe?", detail: "\(safetyDoneCount) of 4") {
            DashboardRowLink(
                icon: "key.fill",
                title: usesSigner ? "Your key is in a signer app" : hasLocalKey ? "Your key is on this device" : "No key on this device",
                detail: usesSigner ? "Nostr Vault asks it to sign." : hasLocalKey ? "Encrypted with your password." : "You can read, but not post or sign.",
                state: hasLocalKey || usesSigner ? .done : .todo
            ) {
                AccountsSettingsView().settingsPage("Accounts")
            }
            DashboardDivider()
            DashboardRowLink(
                icon: "person.2.fill",
                title: "Follow list saved",
                detail: followingBackup.snapshots.last.map { "Last saved \(relative($0.capturedAt))." } ?? "Not saved yet. If a client wipes it, you can't get it back.",
                state: followingBackup.snapshots.isEmpty ? .todo : .done
            ) {
                FollowingBackupSettingsView().settingsPage("Following Backup")
            }
            DashboardDivider()
            DashboardRowLink(
                icon: "laptopcomputer",
                title: "Second copy on your Mac",
                detail: macSyncDetail,
                state: config.macRelayURL.isEmpty ? .todo : .done
            ) {
                MacSyncSettingsPage().settingsPage("Sync with Mac")
            }
            DashboardDivider()
            DashboardRow(
                icon: "doc.zipper",
                title: "Backup file",
                detail: VaultHistory.lastNotesBackup.map { "Last made \(relative($0))." } ?? "Never made. Keep one somewhere off this phone.",
                state: VaultHistory.lastNotesBackup == nil ? .todo : .done
            ) {
                RowButton(title: VaultHistory.lastNotesBackup == nil ? "Make one" : "Make new", isLoading: exporter.running == .notes) {
                    exporter.export(.notes, relayManager: relayManager, config: config)
                }
                .disabled(exporter.isBusy || !relayManager.isRunning)
            }
        }
    }

    private var macSyncDetail: String {
        guard !config.macRelayURL.isEmpty else { return "Not set up. Your Mac can keep a copy that's always on." }
        guard let finished = macSync?.finishedAt, finished > 0 else { return "Set up. Not synced yet." }
        return "Last synced \(relative(Date(timeIntervalSince1970: TimeInterval(finished))))."
    }

    // MARK: - Who can reach you

    /// The vault's own addresses that would go in the published relay list.
    /// Empty for a pocket relay with no Mac relay: there is nothing to list.
    private var publishableOwnRelays: [[String]] {
        HavenConfig.publicRelayListTags(ownRelays: config.ownPublicRelays, read: [], write: [])
    }

    private var publishesRelayList: Bool { config.publishRelayListPerAccount[activeNpub] == true }

    private var reachSection: some View {
        DashboardSection(title: "Who can reach you") {
            DashboardRowLink(
                icon: "person.3.fill",
                title: feedService.wotPubkeys.isEmpty
                    ? "Trust list not built yet"
                    : "\(feedService.wotPubkeys.count.formatted()) people can reach your inbox",
                detail: "People within \(config.chatRelayWotDepth) \(config.chatRelayWotDepth == 1 ? "hop" : "hops") of you. Everyone else is kept out.",
                state: .info
            ) {
                RelayAccessSettingsView().settingsPage("Who Can Reach You")
            }
            DashboardDivider()
            DashboardRowLink(
                icon: "hand.raised.fill",
                title: "Blocked",
                detail: blockedDetail,
                state: .info
            ) {
                BlockedSettingsView().settingsPage("Blocked")
            }
            if !publishableOwnRelays.isEmpty {
                DashboardDivider()
                DashboardRow(
                    icon: "point.3.connected.trianglepath.dotted",
                    title: publishesRelayList ? "Your relay list points here" : "Your relay list leaves out your vault",
                    detail: publishesRelayList ? "Other apps find you at your vault." : "Other apps can't find you here until you publish it.",
                    state: publishesRelayList ? .done : .todo
                ) {
                    if !publishesRelayList {
                        RowButton(title: "Publish") { publishRelayList() }
                            .disabled(!(hasLocalKey || usesSigner))
                    }
                }
            }
        }
    }

    private var blockedDetail: String {
        let count = configService.activeAccountBlockedHexPubkeys.count
        return count == 0 ? "Nobody blocked." : count == 1 ? "1 person blocked." : "\(count) people blocked."
    }

    private func publishRelayList() {
        configService.config.publishRelayListPerAccount[activeNpub] = true
        configService.save()
        NostrService.shared.publishRelayList(forNpub: activeNpub)
    }

    // MARK: - In your vault

    private var ownedSection: some View {
        let messages = kindCounts.isEmpty ? nil : (kindCounts[4] ?? 0) + (kindCounts[1059] ?? 0)
        return DashboardSection(title: "In your vault", framed: false) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                OwnedTile(icon: VaultMode.notes.symbol, title: "Notes", count: kindCounts.isEmpty ? nil : kindCounts[1] ?? 0) {
                    open(.notes)
                }
                OwnedTile(icon: VaultMode.articles.symbol, title: "Articles", count: kindCounts.isEmpty ? nil : kindCounts[30023] ?? 0) {
                    open(.articles)
                }
                OwnedTile(icon: VaultMode.media.symbol, title: "Media", count: mediaCount) {
                    open(.media)
                }
                OwnedTile(icon: "envelope.fill", title: "Messages", count: messages) {
                    dismiss()
                    NotificationCenter.default.post(name: .havenOpenDMInbox, object: nil)
                }
            }
        }
    }

    private func open(_ mode: VaultMode) {
        dismiss()
        mode.select()
    }

    // MARK: - Storage

    private var storageSection: some View {
        let media = statsService.blossomSize
        let cache = statsService.cacheSize + statsService.thumbnailSize
        let notes = max(0, statsService.storageSize - media - cache)
        let total = max(1, notes + media + cache)
        let parts: [(String, Int64, Color)] = [("Notes", notes, .havenPurple), ("Media", media, .blue), ("Cache", cache, .gray)]

        return DashboardSection(title: "Storage", detail: Self.size(statsService.storageSize)) {
            Button { showingStorageBreakdown = true } label: {
                VStack(alignment: .leading, spacing: 12) {
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            ForEach(parts, id: \.0) { part in
                                if part.1 > 0 {
                                    Rectangle()
                                        .fill(part.2)
                                        .frame(width: max(3, (geo.size.width - 4) * CGFloat(part.1) / CGFloat(total)))
                                }
                            }
                        }
                        .frame(width: geo.size.width, alignment: .leading)
                        .background(Color.platformControlBackground)
                        .clipShape(Capsule())
                    }
                    .frame(height: 10)

                    HStack(alignment: .center, spacing: 0) {
                        ForEach(parts, id: \.0) { part in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) {
                                    Circle().fill(part.2).frame(width: 7, height: 7)
                                    Text(part.0).foregroundColor(.primary)
                                }
                                Text(Self.size(part.1))
                                    .foregroundColor(.secondary)
                                    .monospacedDigit()
                                    .padding(.leading, 12)
                            }
                            .font(.appSystem(size: 12))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Image(systemName: "chevron.right")
                            .font(.appSystem(size: 11, weight: .semibold))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Storage breakdown")
        }
    }

    /// "None" rather than ByteCountFormatter's "Zero KB".
    private static func size(_ bytes: Int64) -> String {
        bytes <= 0 ? "None" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Keep it full

    private var actionsEnabled: Bool { relayManager.isRunning || relayManager.isImporting }

    private var keepItFullSection: some View {
        let _ = historyRevision
        return DashboardSection(title: "Keep it full") {
            DashboardRow(
                icon: "arrow.down.circle.fill",
                title: "Import notes",
                detail: relayManager.isImporting
                    ? relayManager.importStatusMessage
                    : "Since \(importStartText). " + (VaultHistory.lastNotesImport.map { "Last ran \(relative($0))." } ?? "Never ran."),
                state: .info,
                progress: relayManager.isImporting ? relayManager.importProgress : nil
            ) {
                RowButton(title: "Import", isLoading: isPreparingImport || relayManager.isImporting) {
                    isPreparingImport = true
                    relayManager.importNotes(config: config)
                }
                .disabled(isPreparingImport || relayManager.isImporting || !actionsEnabled)
            }
            DashboardDivider()
            DashboardRow(
                icon: "photo.on.rectangle.angled",
                title: "Import media",
                detail: mirrorService.state == .mirroring
                    ? (mirrorService.statusText.isEmpty ? "Copying media…" : mirrorService.statusText)
                    : VaultHistory.lastMediaImport.map { "Last ran \(relative($0))." } ?? "Copies the media in your notes here.",
                state: .info,
                progress: mirrorProgress
            ) {
                RowButton(title: "Import", isLoading: mirrorService.state == .mirroring) {
                    mirrorService.runMirror(configService: configService, nostrService: nostrService)
                }
                .disabled(mirrorService.state == .mirroring || !actionsEnabled)
            }
            DashboardDivider()
            DashboardRow(
                icon: "photo.stack",
                title: "Back up media",
                detail: VaultHistory.lastMediaBackup.map { "Last made \(relative($0))." } ?? "Never made.",
                state: .info
            ) {
                RowButton(title: "Back up", isLoading: exporter.running == .media) {
                    exporter.export(.media, relayManager: relayManager, config: config)
                }
                .disabled(exporter.isBusy || !actionsEnabled)
            }
            DashboardDivider()
            DashboardRow(
                icon: "arrow.up.doc.fill",
                title: "Export notes",
                detail: VaultHistory.lastNotesBackup.map { "Last made \(relative($0))." } ?? "Never made.",
                state: .info
            ) {
                RowButton(title: "Export", isLoading: exporter.running == .notes) {
                    exporter.export(.notes, relayManager: relayManager, config: config)
                }
                .disabled(exporter.isBusy || !actionsEnabled)
            }
            if !actionsEnabled || !exporter.statusMessage.isEmpty {
                DashboardDivider()
                HStack(spacing: 6) {
                    if !exporter.statusMessage.isEmpty {
                        Image(systemName: exporter.statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundColor(exporter.statusIsError ? .orange : .havenOnline)
                    }
                    Text(exporter.statusMessage.isEmpty ? "Start your vault to import or back up." : exporter.statusMessage)
                        .foregroundColor(.secondary)
                    Spacer(minLength: 0)
                }
                .font(.appCaption)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    private var mirrorProgress: Double? {
        guard mirrorService.state == .mirroring, let p = mirrorService.progress, p.total > 0 else { return nil }
        return Double(p.completed) / Double(p.total)
    }

    private var importStartText: String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        guard let date = parser.date(from: config.importStartDate) else { return config.importStartDate }
        return date.formatted(.dateTime.month(.abbreviated).year())
    }

    // MARK: - Vault settings

    /// Counted the way Settings › Relays counts its "N relays" chip, so the
    /// two never disagree: every relay in any column, plus your own.
    private var relayCount: Int {
        let ownRelay = config.ownPublicRelays.first { !$0.isEmpty } ?? ""
        let lists = RelayMatrix.Lists(
            read: config.feedRelays,
            write: config.blastrRelays,
            dms: config.dmRelays,
            search: SearchRelaySettings.relays,
            importing: config.importSeedRelays)
        return RelayMatrix.rows(lists, pinned: [ownRelay, config.ownHavenDMInboxURL]).count + (ownRelay.isEmpty ? 0 : 1)
    }

    private var settingsSection: some View {
        DashboardSection(title: "Vault settings") {
            SettingLink(icon: "antenna.radiowaves.left.and.right", title: "Relays", value: "\(relayCount)") {
                RelayMatrixView().settingsPage("Relays")
            }
            DashboardDivider()
            SettingLink(icon: "person.badge.shield.checkmark", title: "Who Can Reach You", value: "\(config.chatRelayWotDepth) \(config.chatRelayWotDepth == 1 ? "hop" : "hops")") {
                RelayAccessSettingsView().settingsPage("Who Can Reach You")
            }
            DashboardDivider()
            SettingLink(icon: "server.rack", title: "Media Servers", value: "\(config.blossomMirrors.count)") {
                BlossomSettingsView().settingsPage("Media Servers")
            }
            DashboardDivider()
            SettingLink(icon: "laptopcomputer", title: "Sync with Mac", value: config.macRelayURL.isEmpty ? "Off" : "On") {
                MacSyncSettingsPage().settingsPage("Sync with Mac")
            }
            DashboardDivider()
            Toggle(isOn: Binding(
                get: { configService.config.autoStartRelay },
                set: { configService.config.autoStartRelay = $0; configService.save() }
            )) {
                RowLabel(icon: "power", title: "Start automatically")
            }
            .tint(.havenPurple)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Activity

    private var activitySection: some View {
        RelayActivityCard(logStore: relayManager.logStore) {
            showingFullActivity = true
        }
        .tutorialAnchor(TutorialContent.relayActivity)
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        DashboardSection(title: "Advanced") {
            SettingLink(icon: "server.rack", title: "Relay details", value: nil) {
                DashboardView()
                    .navigationTitle("Relay details")
            }
            DashboardDivider()
            SettingLink(icon: "photo.on.rectangle", title: "Media server details", value: nil) {
                ScrollView { BlossomDashboardView(embedded: true).padding(.vertical, 10) }
                    .background(Color.platformWindowBackground.ignoresSafeArea())
                    .navigationTitle("Media server details")
            }
            DashboardDivider()
            SettingLink(icon: "text.alignleft", title: "Raw logs", value: nil) {
                LogsView(logStore: relayManager.logStore).settingsPage("Logs")
            }
        }
    }

    private func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }
}

// MARK: - Building blocks

/// A titled card of rows: the section style every Vault Dashboard block uses.
private struct DashboardSection<Content: View>: View {
    let title: String
    var detail: String?
    /// Off for content that draws its own cards, like the tiles.
    var framed = true
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.appSystem(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                if let detail {
                    Text(detail)
                        .font(.appSystem(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            if framed {
                VStack(spacing: 0) { content }
                    .background(Color.platformCardBackground, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.platformCardBorder, lineWidth: 1))
            } else {
                content
            }
        }
    }
}

private struct DashboardDivider: View {
    var body: some View { Divider().padding(.leading, 52) }
}

private enum RowState {
    case done, todo, info

    @MainActor var color: Color {
        switch self {
        case .done: return .havenOnline
        case .todo: return .orange
        case .info: return .havenPurple
        }
    }
}

private struct RowIcon: View {
    let icon: String
    let state: RowState

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: icon)
                .font(.appSystem(size: 14, weight: .semibold))
                .foregroundColor(state.color)
                .frame(width: 30, height: 30)
                .background(state.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            if state != .info {
                Image(systemName: state == .done ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.appSystem(size: 12, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, state.color)
                    .offset(x: 4, y: 4)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct RowText: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.appSystem(size: 15, weight: .semibold))
                .foregroundColor(.primary)
            Text(detail)
                .font(.appSystem(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A row with a trailing control (a button) and an optional progress bar.
private struct DashboardRow<Trailing: View>: View {
    let icon: String
    let title: String
    let detail: String
    let state: RowState
    var progress: Double?
    @ViewBuilder let trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                RowIcon(icon: icon, state: state)
                RowText(title: title, detail: detail)
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(state == .todo ? "Needs attention" : state == .done ? "Done" : "")
                trailing
            }
            if let progress {
                ProgressView(value: min(max(progress, 0), 1))
                    .tint(.havenPurple)
                    .padding(.leading, 42)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

/// A row that opens a settings page.
private struct DashboardRowLink<Destination: View>: View {
    let icon: String
    let title: String
    let detail: String
    let state: RowState
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 12) {
                RowIcon(icon: icon, state: state)
                RowText(title: title, detail: detail)
                if state == .todo {
                    Text("Fix")
                        .font(.appSystem(size: 13, weight: .semibold))
                        .foregroundColor(.orange)
                }
                Image(systemName: "chevron.right")
                    .font(.appSystem(size: 12, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(state == .todo ? "Needs attention" : state == .done ? "Done" : "")
    }
}

private struct RowLabel: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.appSystem(size: 14, weight: .semibold))
                .foregroundColor(.havenPurple)
                .frame(width: 30, height: 30)
                .background(Color.havenPurple.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            Text(title)
                .font(.appSystem(size: 15, weight: .medium))
                .foregroundColor(.primary)
        }
    }
}

/// A quick link to one of the vault's own settings, showing its current value.
private struct SettingLink<Destination: View>: View {
    let icon: String
    let title: String
    let value: String?
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 8) {
                RowLabel(icon: icon, title: title)
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .font(.appSystem(size: 15))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                Image(systemName: "chevron.right")
                    .font(.appSystem(size: 12, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct RowButton: View {
    let title: String
    var isLoading = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title).opacity(isLoading ? 0 : 1)
                if isLoading { ProgressView().controlSize(.small) }
            }
            .font(.appSystem(size: 13, weight: .semibold))
            .foregroundColor(.havenPurple)
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .background(Color.havenPurple.opacity(0.12), in: Capsule())
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

/// One thing the vault holds: a count that opens its list in the Vault tab.
private struct OwnedTile: View {
    let icon: String
    let title: String
    let count: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.appSystem(size: 15, weight: .semibold))
                    .foregroundColor(.havenPurple)
                Group {
                    if let count {
                        Text(count.formatted())
                    } else {
                        Text("—").foregroundColor(.secondary)
                    }
                }
                .font(.appSystem(size: 22, weight: .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                Text(title)
                    .font(.appSystem(size: 13))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(14)
            .background(Color.platformCardBackground, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.platformCardBorder, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(count.map { $0.formatted() } ?? "Loading"))
        .accessibilityHint(Text("Opens \(title.lowercased()) in the Vault tab"))
    }
}

/// Settings › Sync with Mac, whichever form this platform has.
private struct MacSyncSettingsPage: View {
    var body: some View {
        #if os(iOS)
        MacRelaySettingsView()
        #else
        MacRelayDomainSettingsView()
        #endif
    }
}

private extension View {
    /// A settings page pushed from the dashboard, titled like it is in Settings.
    func settingsPage(_ title: String) -> some View {
        navigationTitle(title)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
