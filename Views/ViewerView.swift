import SwiftUI
import AVFoundation
import Combine

struct ViewerView: View {
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var relayManager: RelayProcessManager
    
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
        let rpm = relayManager
        
        Task.detached(priority: .userInitiated) {
            if currentMode == .notes {
                // Compute Notes
                let filtered = currentEvents.filter { event in
                    if event.kind != 1 { return false }
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
                
                await MainActor.run {
                    self.displayNotes = result
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
                        // Only fill in remote items if blossom didn't already provide a better detection
                        if latestItems[key] == nil {
                            latestItems[key] = item
                        }
                    }
                }
                
                var result = Array(latestItems.values).sorted(by: { $0.dateAdded > $1.dateAdded })

                // Fix up items with missing or octet-stream mime types by sniffing remote bytes
                for i in result.indices {
                    let item = result[i]
                    let needsSniff = item.type == .unknown ||
                        (item.mimeType == nil && item.url.pathExtension.isEmpty) ||
                        item.mimeType?.lowercased() == "application/octet-stream"
                    if needsSniff, let sniffed = NostrService.sniffRemoteMime(url: item.url, rpm: rpm) {
                        result[i] = MediaItem(id: item.id, url: item.url, type: sniffed.type, dateAdded: item.dateAdded, pubkey: item.pubkey, tags: item.tags, mimeType: sniffed.mime)
                    }
                }

                let finalResult = result
                await MainActor.run {
                    self.displayMedia = finalResult
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
        VStack(spacing: 0) {
            // MARK: - Header
            VStack(spacing: 12) {
                HStack {
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
                    .background(Color.primary.opacity(0.05))
                    .cornerRadius(24)
                    
                    Spacer()
                    
                    // Filter Tabs
                    HStack(spacing: 2) {
                        FilterButton(title: "All", color: .secondary, isSelected: contentFilter == .all) {
                            contentFilter = .all
                        }
                        FilterButton(title: "My Notes", color: .havenPurple, isSelected: contentFilter == .mine) {
                            contentFilter = .mine
                        }
                        FilterButton(title: "Tagged", color: .blue, isSelected: contentFilter == .tagged) {
                            contentFilter = .tagged
                        }
                        FilterButton(title: "Whitelisted", color: .green, isSelected: contentFilter == .whitelist) {
                            contentFilter = .whitelist
                        }
                    }
                    .padding(4)
                    .background(Color.primary.opacity(0.05))
                    .cornerRadius(8)
                }
                
                HStack {
                    if viewMode == .notes {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Search notes...", text: $searchText)
                            .textFieldStyle(.plain)
                    } else {
                        // Media Source Filter
                        HStack(spacing: 2) {
                            FilterButton(title: "All Sources", color: .secondary, isSelected: mediaSourceFilter == .all) {
                                mediaSourceFilter = .all
                            }
                            FilterButton(title: "Blossom", color: .pink, isSelected: mediaSourceFilter == .blossom) {
                                mediaSourceFilter = .blossom
                            }
                            FilterButton(title: "Cache", color: .orange, isSelected: mediaSourceFilter == .cache) {
                                mediaSourceFilter = .cache
                            }
                        }
                        Spacer()
                    }
                }
                .padding(10)
                .background(Color.platformControlBackground)
                .cornerRadius(8)
            }
            .padding()
            .background(Color.platformWindowBackground)
            
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
                .padding()
                
                if !displayNotes.isEmpty || !displayMedia.isEmpty {
                    Color.clear
                        .frame(height: 1)
                        .padding(.bottom, 20)
                        .onAppear {
                            if !nostrService.isFetching && (!displayNotes.isEmpty || !displayMedia.isEmpty) {
                                loadMore()
                            }
                        }
                        .id(nostrService.events.count) // Force recreate when data changes to re-trigger onAppear if still visible
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.platformTextBackground)
        .onAppear {
            if !initialLoad && relayManager.isRunning && !relayManager.isBooting {
                refreshAll()
                initialLoad = true
            }
        }
        .onDisappear {
            nostrService.resetConnections()
        }
        .onChange(of: relayManager.isBooting) { newValue in
            // When booting transitions from true -> false, we refresh
            if !newValue && relayManager.isRunning {
                refreshAll()
            }
        }
        // Combined trigger: refresh if we weren't running but now are (and not booting)
        .onChange(of: relayManager.isRunning) { newValue in
            if newValue && !relayManager.isBooting && !initialLoad {
                refreshAll()
                initialLoad = true
            }
        }
        .overlay(fullScreenOverlay)
        .onChange(of: searchText) { _ in updateDisplayData() }
        .onChange(of: contentFilter) { _ in updateDisplayData() }
        .onChange(of: mediaSourceFilter) { _ in updateDisplayData() }
        .onChange(of: viewMode) { _ in updateDisplayData() }
        .onChange(of: nostrService.events.count) { _ in updateDisplayData() } // Rough trigger
        .onReceive(nostrService.objectWillChange) { _ in updateDisplayData() } // Better trigger
        .onChange(of: blossomMedia.count) { _ in updateDisplayData() }
        .task {
            // Initial load
            updateDisplayData()
        }
    }
    
    private var notesList: some View {
        Group {
            if displayNotes.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No notes found")
                        .font(.headline)
                    Text("Try changing your filter settings.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 100)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(displayNotes) { event in
                        NoteRow(event: event)
                    }
                }
            }
        }
    }
    
    private var mediaGrid: some View {
        let items = displayMedia
        let isLoading = isRefreshingMedia || nostrService.isFetching
        return Group {
            if items.isEmpty && isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Loading media...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 100)
            } else if items.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No media found")
                        .font(.headline)
                    Text("Try changing your filter settings or upload media.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 100)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                    ForEach(items) { item in
                        MediaGridItem(item: item) {
                            withAnimation(.easeInOut(duration: 0.2)) { selectedMedia = item }
                        }
                    }
                }
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
                                .foregroundColor(.havenPurple.opacity(0.6))
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
        nostrService.fetchNotes(from: urls)
        loadLocalMedia()
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
        nostrService.fetchNotes(from: urls, until: oldestTimestamp - 1)
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
            let config = configService.config
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
                    let date = (attributes?[.creationDate] as? Date) ?? (attributes?[.modificationDate] as? Date) ?? Date()
                    
                    // Same detection pipeline as blossom export: proof (bytes) + claim (relay) → resolve
                    let proof = rpm.detectMimeFromBytes(for: fileURL)
                    let claim = rpm.fetchMimeFromRelay(config: config, sha256: filename)
                    let resolvedMime = rpm.resolveMime(claim: claim, proof: proof)
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
                .font(.system(size: 11, weight: isSelected ? .bold : .regular))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundColor(isSelected ? .white : .primary)
                .background(isSelected ? color : Color.clear)
                .cornerRadius(4)
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
                Text(title)
                    .lineLimit(1)
            }
            .fixedSize()
            .font(.subheadline.bold())
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .foregroundColor(isSelected ? .white : .secondary)
            .background(isSelected ? Color.havenPurple : Color.clear)
            .cornerRadius(20)
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
    
    var cleanContent: String {
        return event.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    var displayName: String {
        if let name = nostrService.profileNames[event.pubkey] {
            return name
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
        Button(action: {
            if let url = event.njumpURL {
                PlatformURL.open(url)
                #if os(macOS)
                NSApplication.shared.hide(nil)
                #endif
            }
        }) {
            VStack(alignment: .leading, spacing: 12) {
                // Header with profile and timestamp
                HStack {
                    if let pictureURL = nostrService.profilePictures[event.pubkey] {
                        CachedAsyncImage(url: pictureURL) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Circle().fill(noteType.color)
                                .overlay(Image(systemName: "person.fill").font(.caption).foregroundColor(.white))
                        }
                        .frame(width: 32, height: 32)
                        .clipShape(Circle())
                    } else {
                        Circle().fill(noteType.color).frame(width: 32, height: 32)
                            .overlay(Image(systemName: "person.fill").font(.caption).foregroundColor(.white))
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName)
                            .font(.subheadline.bold())
                        Text(timeAgo(from: event.createdAtDate))
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: noteType.icon)
                            .font(.system(size: 10))
                        Text(noteType.label)
                    }
                    .font(.caption2.bold()).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(noteType.color.opacity(0.15))
                    .foregroundColor(noteType.color)
                    .cornerRadius(4)
                }
                
                // Text content (if any)
                if !cleanContent.isEmpty {
                    Text(cleanContent)
                        .font(.body)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding()
            .background(isHovered ? noteType.color.opacity(0.06) : Color.platformControlBackground)
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
        .contextMenu {
            if noteType != .mine {
                Button(action: {
                    blockUser(hexPubkey: event.pubkey)
                }) {
                    Label("Block User", systemImage: "hand.raised.fill")
                }
            }
        }
        .onAppear {
            if nostrService.profileNames[event.pubkey] == nil {
                nostrService.fetchMissingProfiles(for: [event.pubkey])
            }
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
        URLSession.shared.dataTask(with: url) { data, response, _ in
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

