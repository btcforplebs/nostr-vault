import SwiftUI
import AVFoundation
import Combine
#if os(iOS)
import Photos
#endif

struct ViewerView: View {
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var relayManager: RelayProcessManager
    @StateObject private var feedService = FeedService.shared
    
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    @State private var viewMode: ViewMode = .notes
    @State private var blossomMedia: [MediaItem] = []
    @State private var selectedMedia: MediaItem? = nil
    @State private var initialLoad = false
    @State private var isLoadingMore = false
    @State private var isRefreshingMedia = false
    @State private var contentFilter: ContentFilter = .all
    @State private var mediaSourceFilter: MediaSourceFilter = .all
    @State private var likesFilter: LikesFilter = .likedByOthers
    @State private var zapsFilter: ZapsFilter = .zappedByOthers

    // Cached display data (computed in background)
    @State private var displayNotes: [NostrEvent] = []
    @State private var displayMedia: [MediaItem] = []
    @State private var displayLikedNotes: [NostrEvent] = []
    /// Maps note ID -> list of pubkeys who reacted to it
    @State private var reactionMap: [String: [String]] = [:]
    @State private var displayZappedNotes: [NostrEvent] = []
    /// Maps note ID -> list of (zapper pubkey, amount in sats)
    @State private var zapMap: [String: [(pubkey: String, amount: Int64)]] = [:]
    #if os(macOS)
    @State private var keyMonitor: Any? = nil
    #endif
    
    @State private var showingNoteId: String?
    @State private var showingProfilePubkey: String?
    @State private var maxDisplayedItems: Int = 50
    #if os(iOS)
    @State private var saveToPhotosMessage: String?
    #endif

    // Debounce mechanism for updateDisplayData
    @State private var updateTask: Task<Void, Never>?
    @State private var updateGeneration: Int = 0
    @State private var dragOffset: CGSize = .zero
    @State private var showingRelayDashboard = false

    // Static regex pattern to avoid recompilation
    nonisolated private static let hexPattern = try! NSRegularExpression(pattern: "[a-f0-9]{64}", options: .caseInsensitive)
    
    enum ContentFilter {
        case all
        case mine
        case tagged
        case whitelist
    }

    enum ViewMode {
        case notes
        case media
        case likes
        case zaps
    }

    enum LikesFilter {
        case myLikes
        case likedByOthers
    }

    enum ZapsFilter {
        case zappedByOthers
        case myZaps
    }
    
    enum MediaSourceFilter {
        case all
        case blossom
        case cache
    }
    
    // MARK: - Background Processing
    
    
    private func scheduleUpdateDisplayData() {
        updateTask?.cancel()
        updateGeneration += 1
        let gen = updateGeneration
        updateTask = Task { @MainActor in
            // Debounce: wait 150ms so rapid-fire triggers coalesce into one update
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, gen == updateGeneration else { return }
            updateDisplayData()
        }
    }

    private func updateDisplayData() {
        // Capture current state strongly for the background task
        let currentFilter = contentFilter
        let currentSearch = searchText
        let currentEvents = nostrService.events
        let currentNoteMedia = nostrService.noteMedia
        let currentBlossom = blossomMedia
        let owner = nostrService.ownerHexPubkey
        let whitelist = configService.whitelistedHexPubkeys
        let blacklist = configService.blacklistedHexPubkeys

        #if DEBUG
        print("updateDisplayData: blossom=\(currentBlossom.count) noteMedia=\(currentNoteMedia.count) events=\(currentEvents.count) filter=\(currentFilter) source=\(mediaSourceFilter)")
        #endif
        let currentMode = viewMode
        let sourceFilter = mediaSourceFilter
        let currentLikesFilter = likesFilter
        let currentZapsFilter = zapsFilter
        let gen = updateGeneration

        Task.detached(priority: .userInitiated) {
            if currentMode == .likes {
                // MARK: - Likes Mode
                let noteKinds = [1, 6, 30023]

                if currentLikesFilter == .likedByOthers {
                    // My notes that received reactions from others
                    let myNoteIds = Set(currentEvents.filter { $0.pubkey == owner && noteKinds.contains($0.kind) }.map { $0.id })

                    // Build reaction map: noteId -> [reactor pubkeys]
                    var rxMap: [String: [String]] = [:]
                    for event in currentEvents where event.kind == 7 && event.pubkey != owner {
                        if let targetId = event.tags.first(where: { $0.count >= 2 && $0[0] == "e" && myNoteIds.contains($0[1]) })?[1] {
                            rxMap[targetId, default: []].append(event.pubkey)
                        }
                    }

                    let likedNoteIds = Set(rxMap.keys)
                    var filtered = currentEvents.filter { noteKinds.contains($0.kind) && likedNoteIds.contains($0.id) }
                    // Sort by number of reactions (most liked first)
                    filtered.sort { (rxMap[$0.id]?.count ?? 0) > (rxMap[$1.id]?.count ?? 0) }

                    let result = currentSearch.isEmpty ? filtered : filtered.filter { $0.content.localizedCaseInsensitiveContains(currentSearch) }

                    guard await MainActor.run(body: { gen == self.updateGeneration }) else { return }
                    await MainActor.run {
                        self.reactionMap = rxMap
                        self.displayLikedNotes = Array(result.prefix(self.maxDisplayedItems))
                    }
                } else {
                    // My Likes: notes I reacted to (kind 7 from me)
                    let myLikedNoteIds = Set(currentEvents.filter { $0.kind == 7 && $0.pubkey == owner }.compactMap { event in
                        event.tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1]
                    })
                    let filtered = currentEvents.filter { noteKinds.contains($0.kind) && myLikedNoteIds.contains($0.id) }

                    let result = currentSearch.isEmpty ? filtered : filtered.filter { $0.content.localizedCaseInsensitiveContains(currentSearch) }

                    guard await MainActor.run(body: { gen == self.updateGeneration }) else { return }
                    await MainActor.run {
                        self.reactionMap = [:]
                        self.displayLikedNotes = Array(result.prefix(self.maxDisplayedItems))
                    }
                }
            } else if currentMode == .zaps {
                // MARK: - Zaps Mode
                let noteKinds = [1, 6, 30023]
                let zapReceipts = currentEvents.filter { $0.kind == 9735 }

                if currentZapsFilter == .zappedByOthers {
                    // My notes that received zaps from others
                    let myNoteIds = Set(currentEvents.filter { $0.pubkey == owner && noteKinds.contains($0.kind) }.map { $0.id })

                    var zMap: [String: [(pubkey: String, amount: Int64)]] = [:]
                    for receipt in zapReceipts {
                        // Extract target note ID from e-tag
                        guard let targetId = receipt.tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1],
                              myNoteIds.contains(targetId) else { continue }
                        // Parse the embedded zap request from "description" tag
                        guard let descJson = receipt.tags.first(where: { $0.count >= 2 && $0[0] == "description" })?[1],
                              let descData = descJson.data(using: .utf8),
                              let zapReq = try? JSONSerialization.jsonObject(with: descData) as? [String: Any],
                              let senderPubkey = zapReq["pubkey"] as? String,
                              senderPubkey != owner else { continue }
                        // Extract amount from zap request tags
                        var amountSats: Int64 = 0
                        if let reqTags = zapReq["tags"] as? [[String]],
                           let amountTag = reqTags.first(where: { $0.count >= 2 && $0[0] == "amount" }),
                           let msats = Int64(amountTag[1]) {
                            amountSats = msats / 1000
                        }
                        zMap[targetId, default: []].append((pubkey: senderPubkey, amount: amountSats))
                    }

                    let zappedNoteIds = Set(zMap.keys)
                    var filtered = currentEvents.filter { noteKinds.contains($0.kind) && zappedNoteIds.contains($0.id) }
                    // Sort by total sats received (most zapped first)
                    filtered.sort { (zMap[$0.id]?.reduce(0) { $0 + $1.amount } ?? 0) > (zMap[$1.id]?.reduce(0) { $0 + $1.amount } ?? 0) }

                    let result = currentSearch.isEmpty ? filtered : filtered.filter { $0.content.localizedCaseInsensitiveContains(currentSearch) }

                    guard await MainActor.run(body: { gen == self.updateGeneration }) else { return }
                    await MainActor.run {
                        self.zapMap = zMap
                        self.displayZappedNotes = Array(result.prefix(self.maxDisplayedItems))
                    }
                } else {
                    // My Zaps: notes I zapped
                    var myZappedNoteIds = Set<String>()
                    for receipt in zapReceipts {
                        guard let descJson = receipt.tags.first(where: { $0.count >= 2 && $0[0] == "description" })?[1],
                              let descData = descJson.data(using: .utf8),
                              let zapReq = try? JSONSerialization.jsonObject(with: descData) as? [String: Any],
                              let senderPubkey = zapReq["pubkey"] as? String,
                              senderPubkey == owner else { continue }
                        if let targetId = receipt.tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1] {
                            myZappedNoteIds.insert(targetId)
                        }
                    }
                    let filtered = currentEvents.filter { noteKinds.contains($0.kind) && myZappedNoteIds.contains($0.id) }

                    let result = currentSearch.isEmpty ? filtered : filtered.filter { $0.content.localizedCaseInsensitiveContains(currentSearch) }

                    guard await MainActor.run(body: { gen == self.updateGeneration }) else { return }
                    await MainActor.run {
                        self.zapMap = [:]
                        self.displayZappedNotes = Array(result.prefix(self.maxDisplayedItems))
                    }
                }
            } else if currentMode == .notes {
                // MARK: - Notes Mode (Kinds: 1, 6, 30023)
                let filtered = currentEvents.filter { event in
                    let validKinds = [1, 6, 30023]
                    if !validKinds.contains(event.kind) { return false }

                    if blacklist.contains(event.pubkey) { return false }

                    switch currentFilter {
                    case .all:
                        let isMine = event.pubkey == owner
                        let isTagged = event.tags.contains { $0.count >= 2 && $0[0] == "p" && $0[1] == owner }
                        let isWhitelisted = whitelist.contains(event.pubkey)
                        return isMine || isTagged || isWhitelisted
                    case .mine: return event.pubkey == owner
                    case .tagged: return event.pubkey != owner && event.tags.contains { $0.count >= 2 && $0[0] == "p" && $0[1] == owner }
                    case .whitelist:
                        return whitelist.contains(event.pubkey) && event.pubkey != owner
                    }
                }

                let result = currentSearch.isEmpty ? filtered : filtered.filter { $0.content.localizedCaseInsensitiveContains(currentSearch) }

                // Skip UI update if a newer generation has been triggered
                guard await MainActor.run(body: { gen == self.updateGeneration }) else { return }

                await MainActor.run {
                    self.displayNotes = Array(result.prefix(self.maxDisplayedItems))
                }
            } else {
                // Compute Media
                var latestItems: [String: MediaItem] = [:]
                
                let remoteItems = currentNoteMedia.filter { item in
                    if let pk = item.pubkey, blacklist.contains(pk) { return false }

                    switch currentFilter {
                    case .all:
                        let isMine = item.pubkey == owner
                        let isTagged = item.tags?.contains { $0.count >= 2 && $0[0] == "p" && $0[1] == owner } ?? false
                        let isWhitelisted = item.pubkey != nil && whitelist.contains(item.pubkey!)
                        return isMine || isTagged || isWhitelisted
                    case .mine: return item.pubkey == owner
                    case .tagged:
                        if item.pubkey == owner { return false }
                        return item.tags?.contains { $0.count >= 2 && $0[0] == "p" && $0[1] == owner } ?? false
                    case .whitelist:
                        guard let pk = item.pubkey else { return false }
                        return whitelist.contains(pk) && pk != owner
                    }
                }
                
                // Build hash → event timestamp lookup from ALL noteMedia (unfiltered)
                // so blossom items get correct dates even when no noteMedia match survives filtering
                var eventTimestamps: [String: Date] = [:]
                for item in currentNoteMedia {
                    let key = self.normalizedKeyStatic(for: item.url)
                    if let existing = eventTimestamps[key] {
                        if item.dateAdded > existing { eventTimestamps[key] = item.dateAdded }
                    } else {
                        eventTimestamps[key] = item.dateAdded
                    }
                }

                // Add blossom items first — they have accurate mime detection from local bytes + relay
                // Apply event timestamps where available instead of file modification dates
                if (currentFilter == .all || currentFilter == .mine) && (sourceFilter == .all || sourceFilter == .blossom) {
                    for item in currentBlossom {
                        let key = self.normalizedKeyStatic(for: item.url)
                        if let eventDate = eventTimestamps[key] {
                            latestItems[key] = MediaItem(
                                id: item.id,
                                url: item.url,
                                type: item.type,
                                dateAdded: eventDate,
                                pubkey: item.pubkey,
                                tags: item.tags,
                                mimeType: item.mimeType
                            )
                        } else {
                            latestItems[key] = item
                        }
                    }
                }

                if sourceFilter == .all || sourceFilter == .cache {
                    for item in remoteItems {
                        let key = self.normalizedKeyStatic(for: item.url)
                        if let existing = latestItems[key] {
                            // Blossom item exists — keep its superior mime detection
                            // but use the nostr event's created_at as the authoritative date
                            latestItems[key] = MediaItem(
                                id: existing.id,
                                url: existing.url,
                                type: existing.type,
                                dateAdded: item.dateAdded, // event timestamp
                                pubkey: item.pubkey ?? existing.pubkey,
                                tags: item.tags ?? existing.tags,
                                mimeType: existing.mimeType ?? item.mimeType
                            )
                        } else {
                            latestItems[key] = item
                        }
                    }
                }
                
                // Partition: items with verified event timestamps first, unmatched blossom items after
                let allItems = Array(latestItems.values)
                let hasEventTimestamp = Set(eventTimestamps.keys)
                var timestamped: [MediaItem] = []
                var unmatched: [MediaItem] = []
                for item in allItems {
                    let key = self.normalizedKeyStatic(for: item.url)
                    if hasEventTimestamp.contains(key) || !self.isLocalBlossomURL(item.url) {
                        timestamped.append(item)
                    } else {
                        unmatched.append(item)
                    }
                }
                timestamped.sort(by: { $0.dateAdded > $1.dateAdded })
                unmatched.sort(by: { $0.dateAdded > $1.dateAdded })
                var result = timestamped + unmatched

                #if DEBUG
                let timestampCount = eventTimestamps.count
                let blossomWithTimestamp = currentBlossom.filter { hasEventTimestamp.contains(self.normalizedKeyStatic(for: $0.url)) }.count
                print("updateDisplayData: eventTimestamps=\(timestampCount) blossomMatched=\(blossomWithTimestamp)/\(currentBlossom.count) timestamped=\(timestamped.count) unmatched=\(unmatched.count)")
                if let first = result.first {
                    let df = DateFormatter()
                    df.dateFormat = "MM/dd HH:mm"
                    print("  first: \(df.string(from: first.dateAdded)) url=\(first.url.lastPathComponent.prefix(12))")
                }
                #endif

                // Fix up items with missing or octet-stream mime types by sniffing remote bytes
                // This is now synchronous and skips remote sniffing for performance
                for i in result.indices {
                    let item = result[i]
                    let needsSniff = item.type == .unknown ||
                        (item.mimeType == nil && item.url.pathExtension.isEmpty) ||
                        item.mimeType?.lowercased() == "application/octet-stream"
                    if needsSniff {
                        let ext = item.url.pathExtension.lowercased()
                        var sniffedType: MediaItem.MediaType = .unknown
                        var sniffedMime: String? = nil
                        
                        if ["jpg", "jpeg", "png", "gif", "webp", "avif", "heic"].contains(ext) {
                            sniffedType = .image
                            sniffedMime = "image/\(ext == "jpg" ? "jpeg" : ext)"
                        } else if ["mp4", "mov", "webm", "avi"].contains(ext) {
                            sniffedType = .video
                            sniffedMime = "video/\(ext)"
                        } else if ["mp3", "wav", "ogg", "m4a", "flac"].contains(ext) {
                            sniffedType = .audio
                            sniffedMime = "audio/\(ext)"
                        }
                        
                        if sniffedType != .unknown {
                            result[i] = MediaItem(id: item.id, url: item.url, type: sniffedType, dateAdded: item.dateAdded, pubkey: item.pubkey, tags: item.tags, mimeType: sniffedMime)
                        }
                    }
                }

                let finalResult = result

                // Skip UI update if a newer generation has been triggered
                guard await MainActor.run(body: { gen == self.updateGeneration }) else { return }

                await MainActor.run {
                    self.displayMedia = Array(finalResult.prefix(self.maxDisplayedItems))
                }
            }
        }
    }
    
    // Check if URL points to the local blossom server (127.0.0.1 or localhost)
    private nonisolated func isLocalBlossomURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "0.0.0.0"
    }

    // Helper for detached task
    private nonisolated func normalizedKeyStatic(for url: URL) -> String {
        let urlString = url.absoluteString
        let lastComponent = url.lastPathComponent
        if lastComponent.count == 64 && lastComponent.allSatisfy({ $0.isHexDigit }) {
             return lastComponent
        }
        if let match = Self.hexPattern.firstMatch(in: urlString, options: [], range: NSRange(urlString.startIndex..., in: urlString)),
           let range = Range(match.range, in: urlString) {
            return String(urlString[range])
        }
        return url.deletingPathExtension().lastPathComponent
    }
    
    var statusColor: Color {
        switch nostrService.connectionColor {
        case "green": return .green
        case "yellow": return .yellow
        case "red": return .red
        default: return .gray
        }
    }
    
    private var viewModeTitle: String {
        switch viewMode {
        case .notes: return "Notes"
        case .media: return "Media"
        case .likes: return "Likes"
        case .zaps: return "Zaps"
        }
    }
    
    var body: some View {
        viewContent
    }
    @ViewBuilder
    private func headerView(isNarrow: Bool) -> some View {
        VStack(spacing: 12) {
            #if os(macOS)
            HStack {
                relayDashboardButton
                Spacer()
            }
            #endif

            if isNarrow {
                VStack(alignment: .leading, spacing: 10) {
                    #if os(macOS)
                    HStack {
                        modeView
                        Spacer()
                    }
                    #endif
                    if viewMode == .notes {
                        ScrollView(.horizontal, showsIndicators: false) {
                            filterView
                        }
                    } else if viewMode == .likes {
                        ScrollView(.horizontal, showsIndicators: false) {
                            likesFilterView
                        }
                    } else if viewMode == .zaps {
                        ScrollView(.horizontal, showsIndicators: false) {
                            zapsFilterView
                        }
                    }
                }
            } else {
                HStack {
                    #if os(macOS)
                    modeView
                    Spacer()
                    #endif
                    if viewMode == .notes {
                        filterView
                    } else if viewMode == .likes {
                        likesFilterView
                    } else if viewMode == .zaps {
                        zapsFilterView
                    }
                }
            }

            searchOrSourceBar
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(red: 0.12, green: 0.12, blue: 0.16))
    }

    @ViewBuilder
    private var relayDashboardButton: some View {
        Button(action: { showingRelayDashboard = true }) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusColor.opacity(0.6), radius: 3)
                Text("Relay Dashboard")
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(statusColor.opacity(0.15))
            .foregroundColor(.primary)
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var searchOrSourceBar: some View {
        HStack {
            if viewMode == .notes || viewMode == .likes || viewMode == .zaps {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 14, weight: .semibold))
                TextField(viewMode == .zaps ? "Search zapped notes..." : viewMode == .likes ? "Search liked notes..." : "Search notes...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .regular))
                    .focused($isSearchFocused)
                    .submitLabel(.search)

                if !searchText.isEmpty {
                    Button(action: {
                        searchText = ""
                        isSearchFocused = false
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    sourceFilterView
                }
            }
        }
        .padding(10)
        .background(Color(red: 0.12, green: 0.12, blue: 0.16))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(red: 0.2, green: 0.2, blue: 0.25), lineWidth: 0.5))
        .onTapGesture {
            if !isSearchFocused && viewMode != .media {
                isSearchFocused = true
            }
        }
    }

    @ViewBuilder
    private var listContent: some View {
        VStack(spacing: 0) {
            if viewMode == .notes {
                notesList
            } else if viewMode == .likes {
                likesList
            } else if viewMode == .zaps {
                zapsList
            } else {
                mediaGrid
            }
        }
        .padding(.vertical, 16)
        .contentShape(Rectangle())
        .onTapGesture {
            isSearchFocused = false
        }
    }

    @ViewBuilder
    private var viewContent: some View {
        GeometryReader { geometry in
            ZStack {
                Color(red: 0.08, green: 0.08, blue: 0.1).ignoresSafeArea()

                VStack(spacing: 0) {
                    headerView(isNarrow: geometry.size.width < 500)

                    Divider()

                    ScrollView {
                        listContent

                        if !displayNotes.isEmpty || !displayMedia.isEmpty || !displayLikedNotes.isEmpty {
                            Color.clear
                                .frame(height: 1)
                                .padding(.bottom, 20)
                                .onAppear {
                                    if !nostrService.isFetching && (!displayNotes.isEmpty || !displayMedia.isEmpty) {
                                        loadMore()
                                    }
                                }
                                .id(nostrService.events.count)
                        }
                    }
                    .refreshable {
                        #if os(iOS)
                        MacRelaySyncService.shared.syncIfConfigured()
                        #endif
                        refreshAll()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                }
            }
        }
        .onAppear {
            if relayManager.isRunning && !relayManager.isBooting {
                if feedService.followedPubkeys.isEmpty {
                    feedService.refresh()
                }
                refreshAll()
                initialLoad = true
            }
        }
        .onDisappear {
            nostrService.resetConnections()
        }
        .onChange(of: relayManager.isBooting) { _, isBooting in
            if !isBooting && relayManager.isRunning {
                refreshAll()
                initialLoad = true
                triggerAutoMirrorIfEnabled()
            }
        }
        .onChange(of: relayManager.isRunning) { _, isRunning in
            if isRunning && !relayManager.isBooting {
                refreshAll()
                initialLoad = true
            }
        }
        .overlay(fullScreenOverlay)
        .modifier(ViewerChangeHandlers(
            viewMode: viewMode,
            likesFilter: likesFilter,
            zapsFilter: zapsFilter,
            searchText: searchText,
            contentFilter: contentFilter,
            mediaSourceFilter: mediaSourceFilter,
            eventsCount: nostrService.events.count,
            noteMediaCount: nostrService.noteMedia.count,
            blacklistedNpubs: configService.config.blacklistedNpubs,
            blossomCount: blossomMedia.count,
            onResetAndUpdate: {
                maxDisplayedItems = 50
                scheduleUpdateDisplayData()
            },
            onUpdate: { scheduleUpdateDisplayData() },
            onViewModeChange: { newMode in
                scheduleUpdateDisplayData()
                if newMode == .likes {
                    fetchMissingLikedNotes()
                }
            },
            onEventsChange: {
                scheduleUpdateDisplayData()
                if viewMode == .likes && likesFilter == .myLikes {
                    fetchMissingLikedNotes()
                }
            }
        ))
        #if os(iOS)
        .onReceive(MirrorService.shared.$state) { newState in
            if newState == .complete {
                loadLocalMedia()
            }
        }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .macRelaySyncComplete)) { _ in
            refreshAll()
        }
        .sheet(item: Binding<IdentifiableString?>(
            get: { showingProfilePubkey.map { IdentifiableString(id: $0) } },
            set: { showingProfilePubkey = $0?.id }
        )) { p in
            ProfileView(pubkey: p.id)
        }
        .sheet(item: Binding<IdentifiableString?>(
            get: { showingNoteId.map { IdentifiableString(id: $0) } },
            set: { showingNoteId = $0?.id }
        )) { noteId in
            NoteDetailViewWrapper(noteId: noteId.id)
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .sheet(isPresented: $showingRelayDashboard) {
            NavigationView {
                DashboardView()
                    .environmentObject(relayManager)
                    .environmentObject(configService)
                    .environmentObject(nostrService)
                    .environmentObject(StatsService.shared)
                    .navigationTitle("Relay Dashboard")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Done") { showingRelayDashboard = false }
                        }
                    }
                    #endif
            }
            #if os(macOS)
            .frame(minWidth: 400, minHeight: 400)
            #endif
        }
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: { showingRelayDashboard = true }) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 12, height: 12)
                        .shadow(color: statusColor.opacity(0.8), radius: 4)
                        .padding(8)
                        .background(Color.primary.opacity(0.08))
                        .clipShape(Circle())
                }
            }
            
            ToolbarItem(placement: .principal) {
                Menu {
                    Button(action: { viewMode = .notes }) {
                        Label("Notes", systemImage: viewMode == .notes ? "checkmark" : "")
                    }
                    Button(action: {
                        viewMode = .media
                        if relayManager.isRunning && !relayManager.isBooting {
                            loadLocalMedia()
                        }
                    }) {
                        Label("Media", systemImage: viewMode == .media ? "checkmark" : "")
                    }
                    Button(action: {
                        viewMode = .likes
                        fetchMissingLikedNotes()
                    }) {
                        Label("Likes", systemImage: viewMode == .likes ? "checkmark" : "")
                    }
                    Button(action: { viewMode = .zaps }) {
                        Label("Zaps", systemImage: viewMode == .zaps ? "checkmark" : "")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(viewModeTitle)
                            .font(.system(size: 16, weight: .semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundColor(Color.havenPurple)
                }
            }
        }
        #endif
    }
    
    private var notesButton: some View {
        ModeButton(title: "Notes", icon: "doc.text", isSelected: viewMode == .notes) {
            viewMode = .notes
        }
    }

    private var mediaButton: some View {
        ModeButton(title: "Media", icon: "photo.on.rectangle", isSelected: viewMode == .media) {
            viewMode = .media
            if relayManager.isRunning && !relayManager.isBooting {
                loadLocalMedia()
            }
        }
    }

    private var likesButton: some View {
        ModeButton(title: "Likes", icon: "heart.fill", isSelected: viewMode == .likes) {
            viewMode = .likes
            fetchMissingLikedNotes()
        }
    }

    private var zapsButton: some View {
        ModeButton(title: "Zaps", icon: "bolt.fill", isSelected: viewMode == .zaps) {
            viewMode = .zaps
        }
    }

    private var modeView: some View {
        HStack(spacing: 4) {
            notesButton
            mediaButton
            likesButton
            zapsButton
        }
        .padding(4)
        .background(Color(red: 0.15, green: 0.15, blue: 0.2))
        .cornerRadius(20)
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(red: 0.2, green: 0.2, blue: 0.25), lineWidth: 0.8))
    }
    
    private var filterView: some View {
        HStack(spacing: 2) {
            FilterButton(title: "All", color: .secondary, isSelected: contentFilter == .all) {
                contentFilter = .all
            }
            FilterButton(title: "My Notes", color: .havenPurple, isSelected: contentFilter == .mine) {
                contentFilter = .mine
            }
            FilterButton(title: "Tagged", color: Color(red: 0.2, green: 0.8, blue: 0.6), isSelected: contentFilter == .tagged) {
                contentFilter = .tagged
            }
            FilterButton(title: "Whitelisted", color: Color(red: 0.2, green: 0.8, blue: 0.6).opacity(0.7), isSelected: contentFilter == .whitelist) {
                contentFilter = .whitelist
            }
        }
        .padding(4)
        .background(Color(red: 0.15, green: 0.15, blue: 0.2))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(red: 0.2, green: 0.2, blue: 0.25), lineWidth: 0.8))
    }
    
    private var sourceFilterView: some View {
        HStack(spacing: 2) {
            FilterButton(title: "All Sources", color: .secondary, isSelected: mediaSourceFilter == .all) {
                mediaSourceFilter = .all
            }
            FilterButton(title: "Blossom", color: .havenPurple, isSelected: mediaSourceFilter == .blossom) {
                mediaSourceFilter = .blossom
            }
            FilterButton(title: "Cache", color: Color(red: 1, green: 0.6, blue: 0.1), isSelected: mediaSourceFilter == .cache) {
                mediaSourceFilter = .cache
            }
        }
        .padding(4)
        .background(Color(red: 0.15, green: 0.15, blue: 0.2))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(red: 0.2, green: 0.2, blue: 0.25), lineWidth: 0.8))
    }
    
    private var likesFilterView: some View {
        HStack(spacing: 2) {
            FilterButton(title: "Liked", icon: "heart.fill", color: .red, isSelected: likesFilter == .likedByOthers) {
                likesFilter = .likedByOthers
            }
            FilterButton(title: "My Likes", icon: "heart", color: .pink, isSelected: likesFilter == .myLikes) {
                likesFilter = .myLikes
            }
        }
        .padding(4)
        .background(Color(red: 0.15, green: 0.15, blue: 0.2))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(red: 0.2, green: 0.2, blue: 0.25), lineWidth: 0.8))
    }

    private var zapsFilterView: some View {
        HStack(spacing: 2) {
            FilterButton(title: "Zapped", icon: "bolt.fill", color: .orange, isSelected: zapsFilter == .zappedByOthers) {
                zapsFilter = .zappedByOthers
            }
            FilterButton(title: "My Zaps", icon: "bolt", color: .yellow, isSelected: zapsFilter == .myZaps) {
                zapsFilter = .myZaps
            }
        }
        .padding(4)
        .background(Color(red: 0.15, green: 0.15, blue: 0.2))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(red: 0.2, green: 0.2, blue: 0.25), lineWidth: 0.8))
    }

    private var likesList: some View {
        let isLoading = nostrService.isFetching || relayManager.isBooting
        return Group {
            if displayLikedNotes.isEmpty && isLoading {
                VStack(spacing: 32) {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Color.havenPurple)
                        VStack(spacing: 8) {
                            Text("Loading likes...")
                                .font(.system(size: 18, weight: .bold, design: .default))
                                .tracking(0.3)
                            Text("This may take a moment")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.6))
                                .tracking(0.5)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.08, green: 0.08, blue: 0.1))
            } else if displayLikedNotes.isEmpty {
                VStack(spacing: 24) {
                    Image(systemName: likesFilter == .likedByOthers ? "heart.slash" : "heart")
                        .font(.system(size: 48, weight: .thin))
                        .foregroundStyle(
                            LinearGradient(
                                gradient: Gradient(colors: [.red, .pink]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    VStack(spacing: 8) {
                        Text(likesFilter == .likedByOthers ? "No reactions yet" : "No liked posts")
                            .font(.system(size: 18, weight: .bold, design: .default))
                            .tracking(0.2)
                        Text(likesFilter == .likedByOthers ? "Reactions on your notes will appear here" : "Posts you've liked will appear here")
                            .font(.system(size: 13, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.3)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.08, green: 0.08, blue: 0.1))
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(displayLikedNotes) { event in
                        VStack(alignment: .leading, spacing: 0) {
                            // Show who liked this post (only in "Liked by Others" mode)
                            if likesFilter == .likedByOthers, let reactors = reactionMap[event.id], !reactors.isEmpty {
                                LikedByRow(reactorPubkeys: reactors)
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 6)
                            }

                            #if os(iOS)
                            NavigationLink(destination: NoteDetailView(note: FeedNote(
                                id: event.id,
                                pubkey: event.pubkey,
                                content: event.content,
                                createdAt: event.createdAtDate,
                                tags: event.tags,
                                kind: event.kind
                            ))) {
                                NoteRow(event: event)
                                    .padding(.horizontal, 16)
                                    .onAppear {
                                        if event.id == displayLikedNotes.last?.id {
                                            loadMoreItems()
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            #else
                            NoteRow(event: event)
                                .padding(.horizontal, 16)
                                .onAppear {
                                    if event.id == displayLikedNotes.last?.id {
                                        loadMoreItems()
                                    }
                                }
                            #endif
                        }
                    }
                }
                .environment(\.openURL, OpenURLAction { url in
                    if url.scheme == "nostr" {
                        let id = url.absoluteString.replacingOccurrences(of: "nostr:", with: "")
                        if id.hasPrefix("npub1") || id.hasPrefix("nprofile1") {
                            self.showingProfilePubkey = id
                            return .handled
                        } else if id.hasPrefix("note1") || id.hasPrefix("nevent1") {
                            self.showingNoteId = id
                            return .handled
                        }
                    }
                    return .systemAction
                })
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var zapsList: some View {
        let isLoading = nostrService.isFetching || relayManager.isBooting
        return Group {
            if displayZappedNotes.isEmpty && isLoading {
                VStack(spacing: 32) {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Color.havenPurple)
                        VStack(spacing: 8) {
                            Text("Loading zaps...")
                                .font(.system(size: 18, weight: .bold, design: .default))
                                .tracking(0.3)
                            Text("This may take a moment")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.6))
                                .tracking(0.5)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.08, green: 0.08, blue: 0.1))
            } else if displayZappedNotes.isEmpty {
                VStack(spacing: 24) {
                    Image(systemName: zapsFilter == .zappedByOthers ? "bolt.slash" : "bolt")
                        .font(.system(size: 48, weight: .thin))
                        .foregroundStyle(
                            LinearGradient(
                                gradient: Gradient(colors: [.orange, .yellow]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    VStack(spacing: 8) {
                        Text(zapsFilter == .zappedByOthers ? "No zaps yet" : "No zapped posts")
                            .font(.system(size: 18, weight: .bold, design: .default))
                            .tracking(0.2)
                        Text(zapsFilter == .zappedByOthers ? "Zaps on your notes will appear here" : "Posts you've zapped will appear here")
                            .font(.system(size: 13, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.3)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.08, green: 0.08, blue: 0.1))
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(displayZappedNotes) { event in
                        VStack(alignment: .leading, spacing: 0) {
                            if zapsFilter == .zappedByOthers, let zappers = zapMap[event.id], !zappers.isEmpty {
                                ZappedByRow(zappers: zappers)
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 6)
                            }

                            #if os(iOS)
                            NavigationLink(destination: NoteDetailView(note: FeedNote(
                                id: event.id,
                                pubkey: event.pubkey,
                                content: event.content,
                                createdAt: event.createdAtDate,
                                tags: event.tags,
                                kind: event.kind
                            ))) {
                                NoteRow(event: event)
                                    .padding(.horizontal, 16)
                                    .onAppear {
                                        if event.id == displayZappedNotes.last?.id {
                                            loadMoreItems()
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            #else
                            NoteRow(event: event)
                                .padding(.horizontal, 16)
                                .onAppear {
                                    if event.id == displayZappedNotes.last?.id {
                                        loadMoreItems()
                                    }
                                }
                            #endif
                        }
                    }
                }
                .environment(\.openURL, OpenURLAction { url in
                    if url.scheme == "nostr" {
                        let id = url.absoluteString.replacingOccurrences(of: "nostr:", with: "")
                        if id.hasPrefix("npub1") || id.hasPrefix("nprofile1") {
                            self.showingProfilePubkey = id
                            return .handled
                        } else if id.hasPrefix("note1") || id.hasPrefix("nevent1") {
                            self.showingNoteId = id
                            return .handled
                        }
                    }
                    return .systemAction
                })
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var notesList: some View {
        let isLoading = nostrService.isFetching || relayManager.isBooting
        return Group {
            if displayNotes.isEmpty && isLoading {
                VStack(spacing: 32) {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Color.havenPurple)

                        VStack(spacing: 8) {
                            Text(relayManager.isBooting ? relayManager.bootStatusMessage.isEmpty ? "Starting relay..." : relayManager.bootStatusMessage : "Loading notes...")
                                .font(.system(size: 18, weight: .bold, design: .default))
                                .tracking(0.3)
                            Text("This may take a moment")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.6))
                                .tracking(0.5)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.08, green: 0.08, blue: 0.1))
            } else if displayNotes.isEmpty {
                VStack(spacing: 24) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 48, weight: .thin))
                        .foregroundStyle(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleLight]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    VStack(spacing: 8) {
                        Text("No notes found")
                            .font(.system(size: 18, weight: .bold, design: .default))
                            .tracking(0.2)

                        Text("Try changing your filter settings")
                            .font(.system(size: 13, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.3)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.08, green: 0.08, blue: 0.1))
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(displayNotes) { event in
                        #if os(iOS)
                        NavigationLink(destination: NoteDetailView(note: FeedNote(
                            id: event.id,
                            pubkey: event.pubkey,
                            content: event.content,
                            createdAt: event.createdAtDate,
                            tags: event.tags,
                            kind: event.kind
                        ))) {
                            NoteRow(event: event)
                                .padding(.horizontal, 16)
                                .onAppear {
                                    if event.id == displayNotes.last?.id {
                                        loadMoreItems()
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        #else
                        NoteRow(event: event)
                            .padding(.horizontal, 16)
                            .onAppear {
                                if event.id == displayNotes.last?.id {
                                    loadMoreItems()
                                }
                            }
                        #endif
                    }
                }
                .environment(\.openURL, OpenURLAction { url in
                    if url.scheme == "nostr" {
                        let id = url.absoluteString.replacingOccurrences(of: "nostr:", with: "")
                        if id.hasPrefix("npub1") || id.hasPrefix("nprofile1") {
                            self.showingProfilePubkey = id
                            return .handled
                        } else if id.hasPrefix("note1") || id.hasPrefix("nevent1") {
                            self.showingNoteId = id
                            return .handled
                        }
                    }
                    return .systemAction
                })
                .frame(maxWidth: .infinity)
            }
        }
    }
    
    private var mediaGrid: some View {
        let items = displayMedia
        let isLoading = isRefreshingMedia || nostrService.isFetching
        return Group {
            if items.isEmpty && isLoading {
                VStack(spacing: 32) {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Color.havenPurple)

                        VStack(spacing: 8) {
                            Text("Loading media...")
                                .font(.system(size: 18, weight: .bold, design: .default))
                                .tracking(0.3)
                            Text("Scanning for uploads")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.6))
                                .tracking(0.5)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.08, green: 0.08, blue: 0.1))
            } else if items.isEmpty {
                VStack(spacing: 24) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 48, weight: .thin))
                        .foregroundStyle(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleLight]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    VStack(spacing: 8) {
                        Text("No media found")
                            .font(.system(size: 18, weight: .bold, design: .default))
                            .tracking(0.2)

                        Text("Try changing your filter settings")
                            .font(.system(size: 13, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.3)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.08, green: 0.08, blue: 0.1))
            } else {
                #if os(macOS)
                let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
                #else
                let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)
                #endif

                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(items) { item in
                        MediaGridItem(item: item) {
                            withAnimation(.easeInOut(duration: 0.2)) { selectedMedia = item }
                        }
                        .onAppear {
                            if item.id == items.last?.id {
                                loadMoreItems()
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }
    
    @ViewBuilder
    private var fullScreenOverlay: some View {
        if let item = selectedMedia {
            ZStack {
                Color.black.opacity(0.9 * max(0, 1.0 - (abs(dragOffset.height) / 300.0)))
                    .edgesIgnoringSafeArea(.all)
                    .onTapGesture { 
                        withAnimation(.easeInOut(duration: 0.2)) { 
                            selectedMedia = nil 
                            dragOffset = .zero
                        } 
                    }
                
                VStack {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Button(action: {
                                PlatformClipboard.copy(item.url.absoluteString)
                            }) {
                                Label("Copy Link", systemImage: "doc.on.doc")
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color.white.opacity(0.1))
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)

                            #if os(iOS)
                            if item.type == .image || item.type == .video {
                                Button(action: {
                                    saveMediaToPhotos(item: item)
                                }) {
                                    Label("Save to Photos", systemImage: "square.and.arrow.down")
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(Color.white.opacity(0.1))
                                        .cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                            }
                            #endif

                            SourceIndicatorView(url: item.url)

                            Spacer()

                            Button(action: { 
                                withAnimation(.easeInOut(duration: 0.2)) { 
                                    selectedMedia = nil 
                                    dragOffset = .zero
                                } 
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title)
                                    .foregroundColor(.white.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                        }
                        #if os(iOS)
                        if let message = saveToPhotosMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundColor(message.contains("Saved") ? .green : .red)
                                .transition(.opacity)
                        }
                        #endif
                    }
                    .padding()
                    .opacity(max(0, 1.0 - (abs(dragOffset.height) / 100.0)))
                    
                    Spacer()
                    
                    TabView(selection: $selectedMedia) {
                        ForEach(displayMedia) { mediaItem in
                            ViewerViewMediaItem(mediaItem: mediaItem)
                                .tag(mediaItem as MediaItem?)
                        }
                    }
                    .mediaTabViewStyleCompat()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .offset(y: dragOffset.height)
                    .scaleEffect(max(0.8, 1.0 - (abs(dragOffset.height) / 1000.0)))
                    .gesture(
                        DragGesture()
                            .onChanged { gesture in
                                // Only capture vertical drags to not conflict with horizontal swiping
                                if abs(gesture.translation.height) > abs(gesture.translation.width) || dragOffset.height != 0 {
                                    dragOffset = CGSize(width: 0, height: gesture.translation.height)
                                }
                            }
                            .onEnded { gesture in
                                if abs(dragOffset.height) > 120 {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        selectedMedia = nil
                                        dragOffset = .zero
                                    }
                                } else {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                                        dragOffset = .zero
                                    }
                                }
                            }
                    )

                    Spacer()

                    Text(item.url.absoluteString)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .padding(.bottom)
                        .opacity(max(0, 1.0 - (abs(dragOffset.height) / 100.0)))
                }
            }
            .transition(.opacity)
            #if os(macOS)
            .onAppear { installKeyMonitor() }
            .onDisappear { removeKeyMonitor() }
            #endif
        }
    }

    private func navigateMedia(direction: Int) {
        guard let current = selectedMedia,
              let index = displayMedia.firstIndex(where: { $0.id == current.id }) else { return }
        let newIndex = index + direction
        guard displayMedia.indices.contains(newIndex) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { selectedMedia = displayMedia[newIndex] }
    }

    #if os(macOS)
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard selectedMedia != nil else { return event }
            switch event.keyCode {
            case 123: // left arrow — previous item in grid
                navigateMedia(direction: -1)
                return nil
            case 124: // right arrow — next item in grid
                navigateMedia(direction: 1)
                return nil
            case 53: // escape
                withAnimation(.easeInOut(duration: 0.2)) { selectedMedia = nil }
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
    #endif

    func refreshAll() {
        // Only proceed if relay is actually ready
        guard relayManager.isRunning && !relayManager.isBooting else {
            #if DEBUG
            print("ViewerView: Skipping refresh - relay not ready")
            #endif
            return
        }

        nostrService.resetConnections()
        // Use the centralized nostrURL which handles local vs remote correctly
        var urls = [
            URL(string: configService.config.nostrURL)!,
            URL(string: configService.config.nostrURL + "/inbox")!
        ]

        // Also query the Mac relay's inbox for tagged notes the local relay may
        // not have (e.g. due to shorter WoT depth or notes missed while suspended).
        let macURL = configService.config.macRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !macURL.isEmpty, let macInbox = URL(string: macURL + "/inbox") {
            urls.append(macInbox)
        }
        
        var authorsSet = Set<String>()
        if let ownerHex = Bech32.decode(configService.config.ownerNpub)?.hexString {
            authorsSet.insert(ownerHex)
        }
        for pk in configService.whitelistedHexPubkeys { authorsSet.insert(pk) }
        let authors = Array(authorsSet)
        
        nostrService.fetchNotes(from: urls, authors: authors)
        loadLocalMedia()
    }
    
    /// Fetch notes referenced by the owner's likes that aren't already in the events array.
    private func fetchMissingLikedNotes() {
        let owner = nostrService.ownerHexPubkey
        guard !owner.isEmpty else { return }

        let likedNoteIds = Set(nostrService.events.filter { $0.kind == 7 && $0.pubkey == owner }.compactMap { event in
            event.tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1]
        })
        let existingIds = Set(nostrService.events.map { $0.id })
        let missingIds = Array(likedNoteIds.subtracting(existingIds))

        guard !missingIds.isEmpty else { return }

        #if DEBUG
        print("ViewerView: Fetching \(missingIds.count) missing liked notes")
        #endif

        var urls = [URL(string: configService.config.nostrURL)!]
        let macURL = configService.config.macRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !macURL.isEmpty, let macRelay = URL(string: macURL) {
            urls.append(macRelay)
        }
        // Also try external relays for notes not on the local relay
        let externalStrs = configService.config.feedRelays.isEmpty ? [
            "wss://relay.damus.io",
            "wss://relay.primal.net",
            "wss://nos.lol",
        ] : configService.config.feedRelays
        urls.append(contentsOf: externalStrs.compactMap { URL(string: $0) })

        nostrService.fetchNotesByIds(missingIds, from: urls)
    }

    func loadMoreItems() {
        let totalCount: Int
        switch viewMode {
        case .notes: totalCount = nostrService.events.count
        case .media: totalCount = blossomMedia.count
        case .likes: totalCount = nostrService.events.count
        case .zaps: totalCount = nostrService.events.count
        }
        if maxDisplayedItems < totalCount {
            maxDisplayedItems += 50
            scheduleUpdateDisplayData()
        }
    }
    
    func loadMore() {
        guard !nostrService.isFetching else { return }
        
        // Get the oldest timestamp from events
        guard let oldestTimestamp = nostrService.events.last?.created_at else { return }
        
        // Request events strictly older than the last one we have
        #if DEBUG
        print("ViewerView: Requesting older events until: \(oldestTimestamp - 1)")
        #endif
        var urls = [
            URL(string: configService.config.nostrURL)!,
            URL(string: configService.config.nostrURL + "/inbox")!
        ]
        let macURL = configService.config.macRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !macURL.isEmpty, let macInbox = URL(string: macURL + "/inbox") {
            urls.append(macInbox)
        }
        
        var authorsSet = Set<String>()
        if let ownerHex = Bech32.decode(configService.config.ownerNpub)?.hexString {
            authorsSet.insert(ownerHex)
        }
        for pk in configService.whitelistedHexPubkeys { authorsSet.insert(pk) }
        let authors = Array(authorsSet)
        
        nostrService.fetchNotes(from: urls, until: oldestTimestamp - 1, authors: authors)
    }
    
    private func triggerAutoMirrorIfEnabled() {
        guard configService.config.autoMirrorMedia else { return }
        MirrorService.shared.runMirror(configService: configService, nostrService: nostrService)
    }

    #if os(iOS)
    private func saveMediaToPhotos(item: MediaItem) {
        saveToPhotosMessage = nil

        Task {
            // Request photo library permission
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                await MainActor.run {
                    saveToPhotosMessage = "Photo library access denied"
                }
                return
            }

            // Download media data
            let session = URLSession(configuration: .default, delegate: LocalhostTrustDelegate(), delegateQueue: nil)
            do {
                let (data, _) = try await session.data(from: item.url)

                if item.type == .video {
                    // Videos need a temp file
                    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
                    try data.write(to: tempURL)
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: tempURL, options: nil)
                    }
                    try? FileManager.default.removeItem(at: tempURL)
                } else {
                    try await PHPhotoLibrary.shared().performChanges {
                        let request = PHAssetCreationRequest.forAsset()
                        let options = PHAssetResourceCreationOptions()
                        request.addResource(with: .photo, data: data, options: options)
                    }
                }

                await MainActor.run {
                    withAnimation { saveToPhotosMessage = "Saved to Photos" }
                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        await MainActor.run { withAnimation { saveToPhotosMessage = nil } }
                    }
                }
            } catch {
                await MainActor.run {
                    saveToPhotosMessage = "Failed to save"
                }
                print("Save to Photos error: \(error.localizedDescription)")
            }
        }
    }
    #endif

    func loadLocalMedia() {
        // Concurrency guard
        if isRefreshingMedia { return }
        
        // Only load if relay is ready
        guard relayManager.isRunning && !relayManager.isBooting else {
            #if DEBUG
            print("ViewerView: Skipping media load - relay not ready")
            #endif
            self.blossomMedia = []
            return
        }
        
        self.isRefreshingMedia = true
        
        // Use a Task for non-blocking I/O
        Task {
            let relayDataDir = configService.relayDataDir
            let blossomPath = configService.config.blossomPath
            let ownerHex = nostrService.ownerHexPubkey
            let webURL = configService.config.webURL
            let rpm = relayManager

            let result = await Task.detached(priority: .background) { () -> [MediaItem] in
                let blossomDir = relayDataDir.appendingPathComponent(blossomPath)
                if !FileManager.default.fileExists(atPath: blossomDir.path) {
                    try? FileManager.default.createDirectory(at: blossomDir, withIntermediateDirectories: true)
                    return []
                }
                
                guard let fileURLs = try? FileManager.default.contentsOfDirectory(at: blossomDir, includingPropertiesForKeys: [.creationDateKey]) else {
                    return []
                }
                
                return fileURLs.compactMap { fileURL -> MediaItem? in
                    let filename = fileURL.lastPathComponent
                    if filename.starts(with: ".") || filename == "LOCK" { return nil }
                    guard let serveURL = URL(string: "\(webURL)/\(filename)") else { return nil }
                    
                    let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                    let date = (attributes?[.modificationDate] as? Date) ?? (attributes?[.creationDate] as? Date) ?? Date()
                    
                    // Same detection pipeline as blossom export: proof (bytes) + claim (relay) → resolve
                    // PERFORMANCE: We skip `fetchMimeFromRelay` here because doing 9000 awaits starves the UI thread pool!
                    let proof = rpm.detectMimeFromBytes(for: fileURL)
                    let resolvedMime = rpm.resolveMime(claim: nil, proof: proof)
                    let mimeType = resolvedMime == "application/octet-stream" ? nil : resolvedMime

                    let mediaType: MediaItem.MediaType
                    if let mime = mimeType {
                        if mime.hasPrefix("video/") { mediaType = .video }
                        else if mime.hasPrefix("audio/") { mediaType = .audio }
                        else if mime.hasPrefix("image/") { mediaType = .image }
                        else { mediaType = .unknown }
                    } else {
                        mediaType = .unknown
                    }

                    return MediaItem(id: UUID(), url: serveURL, type: mediaType, dateAdded: date, pubkey: ownerHex, tags: nil, mimeType: mimeType)
                }
            }.value

            await MainActor.run {
                if self.blossomMedia.count != result.count {
                    #if DEBUG
                    print("ViewerView: Loaded \(result.count) Blossom media items")
                    #endif
                }
                self.blossomMedia = result
                self.isRefreshingMedia = false
            }
        }
    }

}

// MARK: - LikedByRow

struct LikedByRow: View {
    let reactorPubkeys: [String]
    @EnvironmentObject var nostrService: NostrService

    private var uniqueReactors: [String] {
        Array(Set(reactorPubkeys))
    }

    var body: some View {
        let unique = uniqueReactors
        HStack(spacing: 6) {
            Image(systemName: "heart.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.red)

            HStack(spacing: -6) {
                ForEach(unique.prefix(5), id: \.self) { pubkey in
                    let profile = nostrService.profiles[pubkey]
                    AvatarView(url: profile?.pictureURL, pubkey: pubkey, size: 20)
                        .overlay(Circle().stroke(Color.platformSecondaryGroupedBackground, lineWidth: 1.5))
                }
            }

            let names = unique.prefix(3).map { pk -> String in
                nostrService.profiles[pk]?.bestName ?? "npub…" + String(pk.suffix(4))
            }
            let remaining = unique.count - names.count

            Text(likedByText(names: names, remaining: remaining))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)

            Spacer()
        }
        .onAppear {
            let missing = unique.filter { nostrService.profiles[$0] == nil }
            if !missing.isEmpty {
                nostrService.fetchMissingProfiles(for: missing)
            }
        }
    }

    private func likedByText(names: [String], remaining: Int) -> String {
        if names.isEmpty { return "" }
        var text = names.joined(separator: ", ")
        if remaining > 0 {
            text += " +\(remaining) more"
        }
        text += " liked"
        return text
    }
}

// MARK: - ZappedByRow

struct ZappedByRow: View {
    let zappers: [(pubkey: String, amount: Int64)]
    @EnvironmentObject var nostrService: NostrService

    private var uniqueZappers: [String] {
        var seen = Set<String>()
        return zappers.compactMap { z in
            if seen.contains(z.pubkey) { return nil }
            seen.insert(z.pubkey)
            return z.pubkey
        }
    }

    private var totalSats: Int64 {
        zappers.reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        let unique = uniqueZappers
        HStack(spacing: 6) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.orange)

            HStack(spacing: -6) {
                ForEach(unique.prefix(5), id: \.self) { pubkey in
                    let profile = nostrService.profiles[pubkey]
                    AvatarView(url: profile?.pictureURL, pubkey: pubkey, size: 20)
                        .overlay(Circle().stroke(Color.platformSecondaryGroupedBackground, lineWidth: 1.5))
                }
            }

            let names = unique.prefix(3).map { pk -> String in
                nostrService.profiles[pk]?.bestName ?? "npub…" + String(pk.suffix(4))
            }
            let remaining = unique.count - names.count

            Text(zappedByText(names: names, remaining: remaining))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)

            Spacer()
        }
        .onAppear {
            let missing = unique.filter { nostrService.profiles[$0] == nil }
            if !missing.isEmpty {
                nostrService.fetchMissingProfiles(for: missing)
            }
        }
    }

    private func zappedByText(names: [String], remaining: Int) -> String {
        if names.isEmpty { return "" }
        var text = names.joined(separator: ", ")
        if remaining > 0 {
            text += " +\(remaining) more"
        }
        text += " zapped"
        if totalSats > 0 {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            let formatted = formatter.string(from: NSNumber(value: totalSats)) ?? "\(totalSats)"
            text += " · \(formatted) sats"
        }
        return text
    }
}

struct FilterButton: View {
    let title: String
    var icon: String? = nil
    let color: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .bold : .regular, design: .monospaced))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundColor(isSelected ? .white : .secondary)
            .background(isSelected ? color : Color.clear)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? color.opacity(0.5) : Color.clear, lineWidth: 0.8)
            )
            .animation(.easeInOut(duration: 0.15), value: isSelected)
        }
        .buttonStyle(.plain)
    }
}

struct ModeButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .default))
                    .lineLimit(1)
            }
            .fixedSize()
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .foregroundColor(isSelected ? .white : .secondary)
            .background(isSelected ? .havenPurple : Color.clear)
            .cornerRadius(20)
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(isSelected ? .havenPurple.opacity(0.5) : Color.clear, lineWidth: 0.8)
            )
            .contentShape(Rectangle())
            .animation(.easeInOut(duration: 0.2), value: isSelected)
        }
        .buttonStyle(.plain)
    }
}

struct NoteRow: View {
    let event: NostrEvent
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @State private var isHovered = false
    @State private var showingReportDialog = false
    
    var cleanContent: String {
        return event.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// For kind 6 reposts, parse the embedded JSON to extract the original note
    var repostedEvent: NostrEvent? {
        guard event.kind == 6,
              let data = event.content.data(using: .utf8),
              let inner = try? JSONDecoder().decode(NostrEvent.self, from: data) else {
            return nil
        }
        return inner
    }
    
    var displayName: String {
        let profile = nostrService.profiles[event.pubkey]
        if let profile = profile {
            return profile.bestName
        }
        return event.pubkey.prefix(8) + "..." + event.pubkey.suffix(4)
    }
    
    enum NoteType {
        case mine
        case whitelisted
        case tagged
        
        var label: String {
            switch self {
            case .mine: return "My Note"
            case .whitelisted: return "Whitelisted"
            case .tagged: return "Tagged"
            }
        }
        
        var icon: String {
            switch self {
            case .mine: return "pencil.line"
            case .whitelisted: return "checkmark.seal.fill" 
            case .tagged: return "tag.fill"
            }
        }
        
        @MainActor var color: Color {
            switch self {
            case .mine: return .havenPurple
            case .whitelisted: return .green
            case .tagged: return .blue
            }
        }
    }
    
    var noteType: NoteType {
        if event.pubkey == nostrService.ownerHexPubkey {
            return .mine
        }
        if configService.whitelistedHexPubkeys.contains(event.pubkey) {
            return .whitelisted
        }
        return .tagged
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header with profile and timestamp
            HStack(alignment: .center, spacing: 12) {
                if let profile = nostrService.profiles[event.pubkey], let pictureURL = profile.pictureURL {
                    CachedAsyncImage(url: pictureURL) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Circle()
                            .fill(avatarGradientForType(noteType))
                            .overlay(Image(systemName: "person.fill").font(.system(size: 10, weight: .bold)).foregroundColor(.white))
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color(red: 0.2, green: 0.2, blue: 0.25), lineWidth: 0.5))
                } else {
                    Circle()
                        .fill(avatarGradientForType(noteType))
                        .frame(width: 40, height: 40)
                        .overlay(Image(systemName: "person.fill").font(.system(size: 10, weight: .bold)).foregroundColor(.white))
                        .overlay(Circle().stroke(Color(red: 0.2, green: 0.2, blue: 0.25), lineWidth: 0.5))
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(displayName)
                            .font(.system(size: 14, weight: .semibold, design: .default))
                            .lineLimit(1)

                        if event.kind == 6 {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.2.squarepath")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("Reposted")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(.green)
                        }

                        Image(systemName: noteType.icon)
                            .font(.caption2)
                            .foregroundColor(noteType.color)

                        Spacer()

                        Text(timeAgo(from: event.createdAtDate))
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.2)
                    }
                }
            }

            // Repost: show the inner note's content
            if let inner = repostedEvent {
                RepostedNoteView(inner: inner)
                    .environmentObject(nostrService)
            } else if !cleanContent.isEmpty {
                // Regular note content
                Text(NostrContentFormatter.format(cleanContent))
                    .font(.system(size: 15, weight: .regular, design: .default))
                    .foregroundColor(Color(red: 1, green: 1, blue: 1))
                    .lineSpacing(2)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(
            ZStack {
                Color.platformSecondaryGroupedBackground
                Color.havenPurple.opacity(0.015)
            }
        )
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.havenPurple.opacity(0.12), lineWidth: 0.8)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        #if os(iOS)
        .hoverEffect(.lift)
        #endif
        .clipped()
        .buttonStyle(.plain)
        .contextMenu {
            if noteType != .mine {
                Button(action: {
                    showingReportDialog = true
                }) {
                    Label("Report Post", systemImage: "flag.fill")
                }
                
                Divider()
                
                Button(action: {
                    blockUser(hexPubkey: event.pubkey)
                }) {
                    Label("Block User", systemImage: "hand.raised.fill")
                }
            }
        }
        .sheet(isPresented: $showingReportDialog) {
            UGCReportingDialog(eventId: event.id, pubkey: event.pubkey) {
                // Background refresh will handle hiding it, but we can proactively trigger update
                nostrService.objectWillChange.send()
            }
            .environmentObject(nostrService)
            .environmentObject(configService)
        }
        .onAppear {
            if nostrService.profiles[event.pubkey] == nil {
                nostrService.fetchMissingProfiles(for: [event.pubkey])
            }
        }
    }

    private func avatarGradientForType(_ type: NoteType) -> LinearGradient {
        switch type {
        case .mine:
            return LinearGradient(
                gradient: Gradient(colors: [
                    .havenPurple,
                    .havenPurpleLight
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .whitelisted:
            return LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.2, green: 0.8, blue: 0.6),
                    Color(red: 0.1, green: 0.7, blue: 0.5)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .tagged:
            return LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.2, green: 0.5, blue: 0.8),
                    Color(red: 0.3, green: 0.6, blue: 1.0)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private func blockUser(hexPubkey: String) {
        guard let data = Bech32.hexToData(hexPubkey),
              let npub = Bech32.encode(hrp: "npub", data: data) else { return }
        if !configService.config.blacklistedNpubs.contains(npub) {
            configService.config.blacklistedNpubs.append(npub)
            configService.save()
        }
    }

    func timeAgo(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct RepostedNoteView: View {
    let inner: NostrEvent
    @EnvironmentObject var nostrService: NostrService

    private static let mediaPattern = try! NSRegularExpression(
        pattern: #"https?://\S+?\.(?:jpg|jpeg|png|gif|webp|mp4|mov|webm|heic)(?:\?\S+)?"#,
        options: .caseInsensitive
    )

    private var innerDisplayName: String {
        if let profile = nostrService.profiles[inner.pubkey] {
            return profile.bestName
        }
        return inner.pubkey.prefix(8) + "..." + inner.pubkey.suffix(4)
    }

    private var mediaURLs: [URL] {
        let ns = inner.content as NSString
        return Self.mediaPattern.matches(in: inner.content, range: NSRange(location: 0, length: ns.length))
            .compactMap { URL(string: ns.substring(with: $0.range)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Inner note author header
            HStack(spacing: 8) {
                if let profile = nostrService.profiles[inner.pubkey], let pictureURL = profile.pictureURL {
                    CachedAsyncImage(url: pictureURL) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Circle()
                            .fill(Color.gray.opacity(0.3))
                            .overlay(Image(systemName: "person.fill").font(.system(size: 8, weight: .bold)).foregroundColor(.white))
                    }
                    .frame(width: 28, height: 28)
                    .clipShape(Circle())
                } else {
                    Circle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 28, height: 28)
                        .overlay(Image(systemName: "person.fill").font(.system(size: 8, weight: .bold)).foregroundColor(.white))
                }

                Text(innerDisplayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                Spacer()

                Text(timeAgo(from: inner.createdAtDate))
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            // Inner note content
            let urls = mediaURLs
            let content = inner.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                Text(NostrContentFormatter.format(content, mediaURLs: urls))
                    .font(.system(size: 14, weight: .regular, design: .default))
                    .foregroundColor(Color(red: 0.9, green: 0.9, blue: 0.9))
                    .lineSpacing(2)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Image/video previews
            if !urls.isEmpty {
                ForEach(urls.prefix(3), id: \.absoluteString) { url in
                    MediaPreviewRow(url: url)
                }
            }
        }
        .padding(10)
        .background(Color(red: 0.1, green: 0.1, blue: 0.14))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(red: 0.2, green: 0.2, blue: 0.25), lineWidth: 0.5)
        )
        .onAppear {
            if nostrService.profiles[inner.pubkey] == nil {
                nostrService.fetchMissingProfiles(for: [inner.pubkey])
            }
        }
    }

    func timeAgo(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct MediaPreviewRow: View {
    let url: URL
    
    var body: some View {
        Group {
            if url.isVideo {
                VideoThumbnailView(url: url)
                    .aspectRatio(contentMode: .fill)
                    .frame(maxHeight: 250)
                    .cornerRadius(8)
                    .clipped()
            } else if url.isGIF {
                AnimatedImage(url: url, contentMode: .fill, shouldAnimate: true)
                    .frame(maxHeight: 250)
                    .cornerRadius(8)
                    .clipped()
            } else if url.isImage {
                RetryableAsyncImage(url: url, contentMode: .fill)
                    .frame(maxHeight: 250)
                    .cornerRadius(8)
                    .clipped()
            }
        }
        .contentShape(Rectangle())
    }
}

struct MediaGridItem: View {
    let item: MediaItem
    let onSelect: () -> Void
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    @State private var isHovered = false
    @State private var showingReportDialog = false
    #if os(iOS)
    @State private var isMirroringToLocal = false
    @State private var mirrorStatusMessage: String?
    #endif

    var body: some View {
        Color.clear
            .aspectRatio(1.0, contentMode: .fit)
            .overlay(
                Group {
                    // Use item.type instead of url extension checks for Blossom compatibility
                    if item.type == .video {
                        VideoThumbnailView(url: item.url)
                    } else if item.type == .audio {
                        ZStack {
                            Color(red: 0.1, green: 0.1, blue: 0.14)
                            Image(systemName: "waveform")
                                .font(.system(size: 36))
                                .foregroundColor(.havenPurple)
                        }
                    } else if item.type == .unknown {
                        ZStack {
                            Color(red: 0.1, green: 0.1, blue: 0.14)
                            VStack(spacing: 4) {
                                Image(systemName: "doc.fill")
                                    .font(.system(size: 28))
                                    .foregroundColor(.havenPurple.opacity(0.6))
                                if let mime = item.mimeType {
                                    Text(mime)
                                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(4)
                        }
                    } else if item.url.isGIF {
                        AnimatedImage(url: item.url, contentMode: .fill, shouldAnimate: false, targetSize: CGSize(width: 250, height: 250))
                    } else {
                        // Default to image for non-video/audio items
                        RetryableAsyncImage(url: item.url, contentMode: .fill, targetSize: CGSize(width: 250, height: 250))
                    }
                }
            )
            .background(Color.black.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .scaleEffect(isHovered ? 1.04 : 1.0)
            .zIndex(isHovered ? 1.0 : 0.0)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .onHover { hovering in isHovered = hovering }
            .onTapGesture { onSelect() }
        .contextMenu {
            Button(action: {
                PlatformClipboard.copy(item.url.absoluteString)
            }) {
                Label("Copy Link", systemImage: "doc.on.doc")
            }
            #if os(iOS)
            if item.type == .image || item.type == .video {
                Button(action: {
                    saveMediaToPhotos()
                }) {
                    Label("Save to Photos", systemImage: "square.and.arrow.down")
                }
            }
            if isRemoteMedia {
                Button(action: {
                    mirrorToLocalRelay()
                }) {
                    Label(isMirroringToLocal ? "Mirroring..." : "Save to Local Relay", systemImage: "arrow.down.circle")
                }
                .disabled(isMirroringToLocal)
            }
            #endif
            if let pubkey = item.pubkey, pubkey != nostrService.ownerHexPubkey {
                Button(action: {
                    showingReportDialog = true
                }) {
                    Label("Report Media", systemImage: "flag.fill")
                }

                Divider()

                Button(action: {
                    guard let data = Bech32.hexToData(pubkey),
                          let npub = Bech32.encode(hrp: "npub", data: data) else { return }
                    if !configService.config.blacklistedNpubs.contains(npub) {
                        configService.config.blacklistedNpubs.append(npub)
                        configService.save()
                    }
                }) {
                    Label("Block User", systemImage: "hand.raised.fill")
                }
            }
        }
        .sheet(isPresented: $showingReportDialog) {
            UGCReportingDialog(eventId: nil, pubkey: item.pubkey ?? "") {
                nostrService.objectWillChange.send()
            }
            .environmentObject(nostrService)
            .environmentObject(configService)
        }
    }

    #if os(iOS)
    private var isRemoteMedia: Bool {
        let host = item.url.host?.lowercased() ?? ""
        return host != "localhost" && host != "127.0.0.1" && host != "0.0.0.0"
    }

    private func saveMediaToPhotos() {
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { return }

            let session = URLSession(configuration: .default, delegate: LocalhostTrustDelegate(), delegateQueue: nil)
            do {
                let (data, _) = try await session.data(from: item.url)

                if item.type == .video {
                    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
                    try data.write(to: tempURL)
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: tempURL, options: nil)
                    }
                    try? FileManager.default.removeItem(at: tempURL)
                } else {
                    try await PHPhotoLibrary.shared().performChanges {
                        let request = PHAssetCreationRequest.forAsset()
                        request.addResource(with: .photo, data: data, options: PHAssetResourceCreationOptions())
                    }
                }
            } catch {
                print("Save to Photos error: \(error.localizedDescription)")
            }
        }
    }

    private func mirrorToLocalRelay() {
        isMirroringToLocal = true
        Task {
            let service = BlossomService(configService: configService, nostrService: nostrService)
            let success = await service.downloadFromURL(url: item.url)
            await MainActor.run {
                isMirroringToLocal = false
                mirrorStatusMessage = success ? "Saved to local relay" : "Mirror failed"
            }
        }
    }
    #endif
}

struct RetryableAsyncImage: View {
    @EnvironmentObject var configService: ConfigService
    let url: URL
    let contentMode: ContentMode
    var targetSize: CGSize? = nil
    @State private var id = UUID()
    @State private var retryCount = 0
    @State private var cachedImage: PlatformImage? = nil
    @State private var isLoading = false
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image = cachedImage {
                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else if isLoading {
                    ZStack {
                        Rectangle().fill(Color.gray.opacity(0.1))
                        ProgressView().controlSize(.small)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    AsyncImage(url: url, transaction: Transaction(animation: .default)) { phase in
                        switch phase {
                        case .empty:
                            ZStack {
                                Rectangle().fill(Color.gray.opacity(0.1))
                                ProgressView().controlSize(.small)
                            }
                        case .success(let image):
                            image.resizable()
                                .aspectRatio(contentMode: contentMode)
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                                .onAppear {
                                    // checkCache() will handle caching logic
                                }
                        case .failure:
                             ZStack {
                                Rectangle().fill(Color.havenPurplePale.opacity(0.3))
                                VStack(spacing: 6) {
                                    Image(systemName: "photo.fill.on.rectangle.fill")
                                        .font(.system(size: 28))
                                        .foregroundColor(.havenPurple.opacity(0.8))
                                    
                                    VStack(spacing: 2) {
                                        Text("Media Missing")
                                            .font(.system(size: 11, weight: .bold))
                                        Text("Error 404")
                                            .font(.system(size: 9))
                                            .textCase(.uppercase)
                                    }
                                    .foregroundColor(.havenPurple)
                                    
                                    Button(action: {
                                        id = UUID()
                                        retryCount += 1
                                        checkCache()
                                    }) {
                                        Text("Try Again")
                                            .font(.system(size: 10, weight: .bold))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 4)
                                            .background(Color.havenPurple)
                                            .foregroundColor(.white)
                                            .cornerRadius(4)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.top, 4)
                                }
                                .padding(8)
                            }
                        @unknown default:
                            EmptyView()
                        }
                    }
                }
            }
        }
        .id(id)
        .onAppear {
            checkCache()
        }
    }
    
    private func checkCache() {
        // 1. Try to load it directly from disk cache (General cache or Blossom)
        if let data = MediaCacheService.shared.loadFromCache(url: url) {
            Task {
                if let image = await decode(data: data) {
                    await MainActor.run {
                        self.cachedImage = image
                    }
                } else {
                    await handleMissedCache()
                }
            }
            return
        }
        
        Task {
            await handleMissedCache()
        }
    }
    
    private func handleMissedCache() async {
        // 2. If it's a grid item (targetSize set) or not found, try fetching
        // Note: For local Blossom, fetchData just pulls from local server but does not re-cache
        if targetSize != nil || self.cachedImage == nil {
            autoCache()
        }
    }
    
    private func autoCache() {
        isLoading = true
        Task {
            if let data = await MediaCacheService.shared.fetchData(url: url),
               let image = await decode(data: data) {
                await MainActor.run {
                    self.cachedImage = image
                    self.isLoading = false
                }
            } else {
                await MainActor.run {
                    self.isLoading = false
                }
            }
        }
    }
    
    nonisolated private func decode(data: Data) async -> PlatformImage? {
        if let targetSize = targetSize,
           let downsampled = await ImageDownsampler.downsample(data: data, maxDimension: max(targetSize.width, targetSize.height)) {
            return downsampled
        }
        return await Task.detached(priority: .utility) {
            PlatformImage(data: data)
        }.value
    }
}

struct VideoThumbnailView: View {
    let url: URL
    @State private var thumbnail: PlatformImage? = nil
    @State private var isLoading = true
    @State private var id = UUID()
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image = thumbnail {
                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                    
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.white.opacity(0.8))
                        .shadow(radius: 4)
                } else if isLoading {
                    ZStack {
                        Rectangle().fill(Color.gray.opacity(0.1))
                        ProgressView().controlSize(.small)
                    }
                } else {
                    ZStack {
                        Rectangle().fill(Color.havenPurplePale.opacity(0.3))
                        VStack(spacing: 6) {
                            Image(systemName: "video.fill.badge.plus")
                                .font(.system(size: 28))
                                .foregroundColor(.havenPurple.opacity(0.8))
                            
                            VStack(spacing: 2) {
                                Text("No Preview")
                                    .font(.system(size: 11, weight: .bold))
                                Text("Error 404")
                                    .font(.system(size: 9))
                                    .textCase(.uppercase)
                            }
                            .foregroundColor(.havenPurple)
                            
                            Button(action: {
                                id = UUID()
                                loadThumbnail()
                            }) {
                                Text("Try Again")
                                    .font(.system(size: 10, weight: .bold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Color.havenPurple)
                                    .foregroundColor(.white)
                                    .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 4)
                        }
                        .padding(8)
                    }
                }
            }
        }
        .id(id)
        .onAppear {
            loadThumbnail()
        }
    }
    
    private func loadThumbnail() {
        isLoading = true
        
        Task {
            // 1. Check if we already have it locally (cached or blossom)
            if !MediaCacheService.shared.isCached(url: url) && !MediaCacheService.shared.getSource(for: url).isLocal {
                guard let _ = await MediaCacheService.shared.fetchData(url: url) else {
                    await MainActor.run { self.isLoading = false }
                    return
                }
            }
            
            // 2. Generate using the throttled service
            if let image = await MediaCacheService.shared.generateThumbnail(for: url) {
                await MainActor.run {
                    self.thumbnail = image
                    self.isLoading = false
                }
            } else {
                await MainActor.run {
                    self.isLoading = false
                }
            }
        }
    }
}

struct SourceIndicatorView: View {
    let url: URL
    @State private var source: MediaCacheService.MediaSource = .remote
    @State private var isCaching = false
    
    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: source.icon)
                Text(source.rawValue)
                    .font(.system(size: 11, weight: .bold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(source.color.opacity(0.2))
            .foregroundColor(source.color)
            .cornerRadius(20)
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(source.color.opacity(0.3), lineWidth: 1)
            )
            
            if source == .remote {
                Button(action: cacheMedia) {
                    if isCaching {
                        ProgressView().controlSize(.small)
                            .frame(width: 16, height: 16)
                    } else {
                        Label("Cache Locally", systemImage: "square.and.arrow.down")
                            .font(.system(size: 11, weight: .bold))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isCaching)
            }
        }
        .onAppear {
            updateSource()
        }
    }
    
    private func updateSource() {
        source = MediaCacheService.shared.getSource(for: url)
    }
    
    private func cacheMedia() {
        isCaching = true
        MediaSessionService.shared.session.dataTask(with: url) { data, response, _ in
            if let data = data, let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                MediaCacheService.shared.saveToCache(url: url, data: data)
                DispatchQueue.main.async {
                    source = .cached
                    isCaching = false
                }
            } else {
                DispatchQueue.main.async {
                    isCaching = false
                }
            }
        }.resume()
    }
}

// MARK: - ViewerChangeHandlers

/// Extracted onChange modifiers to reduce type-checker complexity in ViewerView.
struct ViewerChangeHandlers: ViewModifier {
    let viewMode: ViewerView.ViewMode
    let likesFilter: ViewerView.LikesFilter
    let zapsFilter: ViewerView.ZapsFilter
    let searchText: String
    let contentFilter: ViewerView.ContentFilter
    let mediaSourceFilter: ViewerView.MediaSourceFilter
    let eventsCount: Int
    let noteMediaCount: Int
    let blacklistedNpubs: [String]
    let blossomCount: Int
    let onResetAndUpdate: () -> Void
    let onUpdate: () -> Void
    let onViewModeChange: (ViewerView.ViewMode) -> Void
    let onEventsChange: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: searchText) { _, _ in onResetAndUpdate() }
            .onChange(of: contentFilter) { _, _ in onResetAndUpdate() }
            .onChange(of: mediaSourceFilter) { _, _ in onUpdate() }
            .onChange(of: likesFilter) { _, _ in onResetAndUpdate() }
            .onChange(of: zapsFilter) { _, _ in onResetAndUpdate() }
            .onChange(of: viewMode) { _, newMode in onViewModeChange(newMode) }
            .onChange(of: eventsCount) { _, _ in onEventsChange() }
            .onChange(of: noteMediaCount) { _, _ in onUpdate() }
            .onChange(of: blacklistedNpubs) { _, _ in onUpdate() }
            .onChange(of: blossomCount) { _, _ in onUpdate() }
    }
}

struct ViewerViewMediaItem: View {
    let mediaItem: MediaItem
    @State private var resolvedType: MediaItem.MediaType
    @State private var isLoadingType = false
    
    init(mediaItem: MediaItem) {
        self.mediaItem = mediaItem
        self._resolvedType = State(initialValue: mediaItem.type)
    }
    
    var body: some View {
        Group {
            if isLoadingType {
                ProgressView()
                    .tint(.white)
            } else if resolvedType == .video {
                VideoPlayerView(url: mediaItem.url)
            } else if resolvedType == .audio {
                AudioPlayerView(url: mediaItem.url)
            } else if resolvedType == .unknown {
                VStack(spacing: 12) {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 64))
                        .foregroundColor(Color.havenPurple.opacity(0.6))
                    if let mime = mediaItem.mimeType {
                        Text(mime)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                    } else {
                        Text("Unknown Format")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                }
            } else if mediaItem.url.isGIF {
                AnimatedImage(url: mediaItem.url, contentMode: .fit, shouldAnimate: true)
            } else {
                RetryableAsyncImage(url: mediaItem.url, contentMode: .fit)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            detectType()
        }
    }
    
    private func detectType() {
        if resolvedType != .unknown {
            return
        }
        
        let ext = mediaItem.url.pathExtension.lowercased()
        if ["mp4", "mov", "webm", "avi"].contains(ext) {
            resolvedType = .video
        } else if ["jpg", "jpeg", "png", "gif", "webp", "avif", "heic"].contains(ext) {
            resolvedType = .image
        } else if ["mp3", "wav", "ogg", "m4a", "flac"].contains(ext) {
            resolvedType = .audio
        } else if let cached = MediaTypeDetector.shared.getCachedContentType(for: mediaItem.url) {
            if MediaTypeDetector.shared.isVideoContentType(cached) {
                resolvedType = .video
            } else if MediaTypeDetector.shared.isImageContentType(cached) {
                resolvedType = .image
            } else {
                resolvedType = .unknown
            }
        } else {
            isLoadingType = true
            MediaTypeDetector.shared.detectContentType(for: mediaItem.url) { detectedType in
                isLoadingType = false
                if let detectedType = detectedType {
                    if MediaTypeDetector.shared.isVideoContentType(detectedType) {
                        resolvedType = .video
                    } else if MediaTypeDetector.shared.isImageContentType(detectedType) {
                        resolvedType = .image
                    } else {
                        resolvedType = .unknown
                    }
                } else {
                    resolvedType = .unknown
                }
            }
        }
    }
}

