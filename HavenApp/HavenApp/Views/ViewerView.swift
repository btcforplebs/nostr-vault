import SwiftUI
import AVFoundation
import Combine

struct ViewerView: View {
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var relayManager: RelayProcessManager
    @StateObject private var feedService = FeedService.shared
    
    @State private var searchText = ""
    @State private var viewMode: ViewMode = .notes
    @State private var blossomMedia: [MediaItem] = []
    @State private var selectedMedia: MediaItem? = nil
    @State private var initialLoad = false
    @State private var isLoadingMore = false
    @State private var isRefreshingMedia = false
    @State private var contentFilter: ContentFilter = .all
    @State private var mediaSourceFilter: MediaSourceFilter = .all
    
    // Cached display data (computed in background)
    @State private var displayNotes: [NostrEvent] = []
    @State private var displayMedia: [MediaItem] = []
    #if os(macOS)
    @State private var keyMonitor: Any? = nil
    #endif
    
    @State private var showingNoteId: String?
    @State private var showingProfilePubkey: String?
    @State private var maxDisplayedItems: Int = 50

    // Debounce mechanism for updateDisplayData
    @State private var updateTask: Task<Void, Never>?
    @State private var updateGeneration: Int = 0

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
        let currentMode = viewMode
        let sourceFilter = mediaSourceFilter
        let gen = updateGeneration

        Task.detached(priority: .userInitiated) {
            if currentMode == .notes {
                // Compute Notes (Kinds: 1, 6, 30023)
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
                
                // Add blossom items first — they have accurate mime detection from local bytes + relay
                if (currentFilter == .all || currentFilter == .mine) && (sourceFilter == .all || sourceFilter == .blossom) {
                    for item in currentBlossom {
                        let key = self.normalizedKeyStatic(for: item.url)
                        latestItems[key] = item
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
                
                var result = Array(latestItems.values).sorted(by: { $0.dateAdded > $1.dateAdded })

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
    
    var body: some View {
        viewContent
    }
    @ViewBuilder
    private var viewContent: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // MARK: - Header
                VStack(spacing: 12) {
                    let isNarrow = geometry.size.width < 500
                    
                    if isNarrow {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                modeView
                                Spacer()
                            }
                            ScrollView(.horizontal, showsIndicators: false) {
                                filterView
                            }
                        }
                    } else {
                        HStack {
                            modeView
                            Spacer()
                            filterView
                        }
                    }
                    
                    HStack {
                        if viewMode == .notes {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)
                                .font(.system(size: 14, weight: .semibold))
                            TextField("Search notes...", text: $searchText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 14, weight: .regular))
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
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.platformControlBackground)

                Divider()

                // MARK: - List Content
                ScrollView {
                    VStack(spacing: 0) {
                        if viewMode == .notes {
                            notesList
                        } else {
                            mediaGrid
                        }
                    }
                    .padding(.vertical, 16)

                    if !displayNotes.isEmpty || !displayMedia.isEmpty {
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
            .background(Color.platformControlBackground)
        }
        .onAppear {
            if !initialLoad && relayManager.isRunning && !relayManager.isBooting {
                // Ensure contacts are loaded first so we have followedPubkeys
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
            if !isBooting && relayManager.isRunning && !initialLoad {
                refreshAll()
                initialLoad = true
            }
        }
        .onChange(of: relayManager.isRunning) { _, isRunning in
            if isRunning && !relayManager.isBooting && !initialLoad {
                refreshAll()
                initialLoad = true
            }
        }
        .overlay(fullScreenOverlay)
        .onChange(of: searchText) { _, _ in 
            maxDisplayedItems = 50
            scheduleUpdateDisplayData() 
        }
        .onChange(of: contentFilter) { _, _ in 
            maxDisplayedItems = 50
            scheduleUpdateDisplayData() 
        }
        .onChange(of: mediaSourceFilter) { _, _ in scheduleUpdateDisplayData() }
        .onChange(of: viewMode) { _, _ in scheduleUpdateDisplayData() }
        .onChange(of: nostrService.events.count) { _, _ in scheduleUpdateDisplayData() }
        .onChange(of: configService.config.blacklistedNpubs) { _, _ in scheduleUpdateDisplayData() }
        .onChange(of: blossomMedia.count) { _, _ in scheduleUpdateDisplayData() }
        .onReceive(NotificationCenter.default.publisher(for: .macRelaySyncComplete)) { _ in
            // Mac relay sync just injected new events — refresh to show them
            refreshAll()
        }
        .task {
            updateDisplayData()
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
    }
    
    private var modeView: some View {
        HStack(spacing: 4) {
            ModeButton(title: "Notes", icon: "doc.text", isSelected: viewMode == .notes) {
                viewMode = .notes
            }
            ModeButton(title: "Media", icon: "photo.on.rectangle", isSelected: viewMode == .media) {
                viewMode = .media
                // Only load media if relay is ready
                if relayManager.isRunning && !relayManager.isBooting {
                    loadLocalMedia()
                }
            }
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
                .background(Color.platformControlBackground)
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
                .background(Color.platformControlBackground)
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
                .background(Color.platformControlBackground)
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
                .background(Color.platformControlBackground)
            } else {
                #if os(macOS)
                let minWidth: CGFloat = 180
                #else
                let minWidth: CGFloat = 140
                #endif
                
                LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth), spacing: 12)], spacing: 12) {
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
                .padding(.horizontal, 16)
            }
        }
    }
    
    @ViewBuilder
    private var fullScreenOverlay: some View {
        if let item = selectedMedia {
            ZStack {
                Color.black.opacity(0.9)
                    .edgesIgnoringSafeArea(.all)
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { selectedMedia = nil } }
                
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
                            
                            SourceIndicatorView(url: item.url)
                            
                            Spacer()
                            
                            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { selectedMedia = nil } }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title)
                                    .foregroundColor(.white.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                    
                    Spacer()
                    
                    if item.type == .video {
                        VideoPlayerView(url: item.url)
                            .frame(minWidth: 480, minHeight: 320)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .id(item.url)
                    } else if item.type == .audio {
                        AudioPlayerView(url: item.url)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .id(item.url)
                    } else if item.type == .unknown {
                        VStack(spacing: 12) {
                            Image(systemName: "doc.fill")
                                .font(.system(size: 64))
                                .foregroundColor(Color.havenPurple.opacity(0.6))
                            if let mime = item.mimeType {
                                Text(mime)
                                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                                    .foregroundColor(.secondary)
                            } else {
                                Text("Unknown Format")
                                    .font(.headline)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if item.url.isGIF {
                        AnimatedImage(url: item.url, contentMode: .fit, shouldAnimate: true)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .id(item.url)
                    } else {
                        // Default to image for non-video/audio items
                        RetryableAsyncImage(url: item.url, contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .id(item.url)
                    }

                    Spacer()

                    Text(item.url.absoluteString)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .padding(.bottom)
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
        let urls = [
            URL(string: configService.config.nostrURL)!,
            URL(string: configService.config.nostrURL + "/inbox")!
        ]
        
        var authorsSet = Set<String>()
        if let ownerHex = Bech32.decode(configService.config.ownerNpub)?.hexString {
            authorsSet.insert(ownerHex)
        }
        for pk in configService.whitelistedHexPubkeys { authorsSet.insert(pk) }
        let authors = Array(authorsSet)
        
        nostrService.fetchNotes(from: urls, authors: authors)
        loadLocalMedia()
    }
    
    func loadMoreItems() {
        if maxDisplayedItems < (viewMode == .notes ? nostrService.events.count : blossomMedia.count) {
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
        let urls = [
            URL(string: configService.config.nostrURL)!,
            URL(string: configService.config.nostrURL + "/inbox")!
        ]
        
        var authorsSet = Set<String>()
        if let ownerHex = Bech32.decode(configService.config.ownerNpub)?.hexString {
            authorsSet.insert(ownerHex)
        }
        for pk in configService.whitelistedHexPubkeys { authorsSet.insert(pk) }
        let authors = Array(authorsSet)
        
        nostrService.fetchNotes(from: urls, until: oldestTimestamp - 1, authors: authors)
    }
    
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

struct FilterButton: View {
    let title: String
    let color: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .bold : .regular, design: .monospaced))
                .lineLimit(1)
                .fixedSize()
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
        
        var color: Color {
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

            // Text content (if any)
            if !cleanContent.isEmpty {
                Text(NostrContentFormatter.format(cleanContent))
                    .font(.system(size: 15, weight: .regular, design: .default))
                    .foregroundColor(Color(red: 1, green: 1, blue: 1))
                    .lineSpacing(2)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Color.platformSecondaryGroupedBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.platformSeparator, lineWidth: 0.8)
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

    var body: some View {
        ZStack {
            Group {
                // Use item.type instead of url extension checks for Blossom compatibility
                if item.type == .video {
                    VideoThumbnailView(url: item.url)
                        // VideoThumbnailView internally uses .fill and resizable
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if item.type == .audio {
                    ZStack {
                        Rectangle().fill(Color.gray.opacity(0.1))
                        Image(systemName: "waveform")
                            .font(.system(size: 40))
                            .foregroundColor(.havenPurple)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if item.type == .unknown {
                    ZStack {
                        Rectangle().fill(Color.gray.opacity(0.1))
                        VStack(spacing: 4) {
                            Image(systemName: "doc.fill")
                                .font(.system(size: 32))
                                .foregroundColor(.havenPurple.opacity(0.6))
                            if let mime = item.mimeType {
                                Text(mime)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if item.url.isGIF {
                    AnimatedImage(url: item.url, contentMode: .fill, shouldAnimate: false, targetSize: CGSize(width: 200, height: 200))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Default to image for non-video/audio items
                    RetryableAsyncImage(url: item.url, contentMode: .fill, targetSize: CGSize(width: 200, height: 200))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(height: 140) // Fixed height for grid rows
        .frame(maxWidth: .infinity) // Fill column width
        .background(Color.black.opacity(0.1)) // Placeholder bg
        .clipped() // STRICT CLIPPING IS KEY
        .cornerRadius(8)
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onHover { hovering in isHovered = hovering }
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .contextMenu {
            Button(action: {
                PlatformClipboard.copy(item.url.absoluteString)
            }) {
                Label("Copy Link", systemImage: "doc.on.doc")
            }
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

