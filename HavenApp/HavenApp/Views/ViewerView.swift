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
    
    var filteredNotes: [NostrEvent] {
        let displayableEvents = nostrService.events.filter { event in
            // Basic Filter: Only View 1 (Text Notes)
            if event.kind != 1 { return false }
            
            // Content Filter
            switch contentFilter {
            case .all: 
                // User requested "All" to include Mine + Tagged + Whitelisted
                let isMine = event.pubkey == nostrService.ownerHexPubkey
                let isTagged = event.tags.contains { $0.count >= 2 && $0[0] == "p" && $0[1] == nostrService.ownerHexPubkey }
                let isWhitelisted = configService.whitelistedHexPubkeys.contains(event.pubkey)
                return isMine || isTagged || isWhitelisted
            case .mine: return event.pubkey == nostrService.ownerHexPubkey
            case .tagged: return event.pubkey != nostrService.ownerHexPubkey && event.tags.contains { $0.count >= 2 && $0[0] == "p" && $0[1] == nostrService.ownerHexPubkey }
            case .whitelist:
                return configService.whitelistedHexPubkeys.contains(event.pubkey) && event.pubkey != nostrService.ownerHexPubkey
            }
        }
        
        if searchText.isEmpty {
            return displayableEvents
        }
        return displayableEvents.filter { $0.content.localizedCaseInsensitiveContains(searchText) }
    }
    
    var allMediaItems: [MediaItem] {
        // Use Nostr event items (noteMedia) as the primary source for proper timestamps,
        // then include local blossom files that don't have a corresponding event.
        var latestItems: [String: MediaItem] = [:]

        func normalizedKey(for url: URL) -> String {
            // Robustly extract the 64-character hash from the URL
            // This handles cases like:
            // - http://local/hash
            // - https://remote/hash.jpg
            // - https://remote/hash?token=123

            let urlString = url.absoluteString

            // Look for 64 hex characters
            let pattern = "[a-f0-9]{64}"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: urlString, options: [], range: NSRange(urlString.startIndex..., in: urlString)),
               let range = Range(match.range, in: urlString) {
                return String(urlString[range])
            }

            // Fallback for non-standard filenames: strip query and extension
            return url.deletingPathExtension().lastPathComponent
        }

        // 1. Filter remote items (from Nostr events) based on content filter
        let remoteItems = nostrService.noteMedia.filter { item in
            switch contentFilter {
            case .all:
                // User requested "All" to include Mine + Tagged + Whitelisted
                let isMine = item.pubkey == nostrService.ownerHexPubkey
                let isTagged = item.tags?.contains { $0.count >= 2 && $0[0] == "p" && $0[1] == nostrService.ownerHexPubkey } ?? false
                let isWhitelisted = item.pubkey != nil && configService.whitelistedHexPubkeys.contains(item.pubkey!)
                return isMine || isTagged || isWhitelisted
            case .mine: return item.pubkey == nostrService.ownerHexPubkey
            case .tagged:
                if item.pubkey == nostrService.ownerHexPubkey { return false }
                if let tags = item.tags {
                    return tags.contains { $0.count >= 2 && $0[0] == "p" && $0[1] == nostrService.ownerHexPubkey }
                }
                return false
            case .whitelist:
                if let pubkey = item.pubkey {
                    return configService.whitelistedHexPubkeys.contains(pubkey) && pubkey != nostrService.ownerHexPubkey
                }
                return false
            }
        }

        // 2. Add remote items (these have proper event timestamps)
        for item in remoteItems {
            latestItems[normalizedKey(for: item.url)] = item
        }

        // 3. Include local blossom files that don't already have a corresponding event.
        //    Only for "All" and "Mine" filters since local blobs are owned by this relay.
        if contentFilter == .all || contentFilter == .mine {
            for item in blossomMedia {
                let key = normalizedKey(for: item.url)
                if latestItems[key] == nil {
                    latestItems[key] = item
                }
            }
        }

        return Array(latestItems.values).sorted(by: { $0.dateAdded > $1.dateAdded })
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
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search notes...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(10)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
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
                
                if !filteredNotes.isEmpty || !allMediaItems.isEmpty {
                    Color.clear
                        .frame(height: 1)
                        .padding(.bottom, 20)
                        .onAppear {
                            if !nostrService.isFetching && (!filteredNotes.isEmpty || !allMediaItems.isEmpty) {
                                loadMore()
                            }
                        }
                        .id(nostrService.events.count) // Force recreate when data changes to re-trigger onAppear if still visible
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(NSColor.textBackgroundColor))
        .onAppear {
            if !initialLoad && relayManager.isRunning && !relayManager.isBooting {
                refreshAll()
                initialLoad = true
            }
        }
        .onDisappear {
            nostrService.resetConnections()
        }
        .onChange(of: relayManager.isBooting) { oldValue, newValue in
            // When booting transitions from true -> false, we refresh
            if !newValue && relayManager.isRunning {
                refreshAll()
            }
        }
        // Combined trigger: refresh if we weren't running but now are (and not booting)
        .onChange(of: relayManager.isRunning) { oldValue, newValue in
            if newValue && !relayManager.isBooting && !initialLoad {
                refreshAll()
                initialLoad = true
            }
        }
        .overlay(fullScreenOverlay)
    }
    
    private var notesList: some View {
        Group {
            if filteredNotes.isEmpty {
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
                    ForEach(filteredNotes) { event in
                        NoteRow(event: event)
                    }
                }
            }
        }
    }
    
    private var mediaGrid: some View {
        let items = allMediaItems
        return Group {
            if items.isEmpty {
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
                            selectedMedia = item
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
                    .onTapGesture { selectedMedia = nil }
                
                VStack {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Button(action: {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(item.url.absoluteString, forType: .string)
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
                            
                            Button(action: { selectedMedia = nil }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title)
                                    .foregroundColor(.white.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                    
                    Spacer()
                    
                    // Use item.type instead of url extension checks for Blossom compatibility
                    if item.type == .video {
                        VideoPlayerView(url: item.url)
                            .frame(minWidth: 480, minHeight: 320)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if item.url.isGIF {
                        AnimatedImage(url: item.url, contentMode: .fit, shouldAnimate: true)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        // Default to image for non-video items
                        RetryableAsyncImage(url: item.url, contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    
                    Spacer()
                    
                    Text(item.url.absoluteString)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .padding(.bottom)
                }
            }
            .transition(.opacity)
        }
    }
    
    func refreshAll() {
        // Only proceed if relay is actually ready
        guard relayManager.isRunning && !relayManager.isBooting else {
            print("ViewerView: Skipping refresh - relay not ready")
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
        print("ViewerView: Requesting older events until: \(oldestTimestamp - 1)")
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
            print("ViewerView: Skipping media load - relay not ready")
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
                    
                    var mediaType: MediaItem.MediaType = .image
                    if serveURL.pathExtension.isEmpty {
                        if let handle = try? FileHandle(forReadingFrom: fileURL),
                           let data = try? handle.read(upToCount: 12),
                           data.count >= 12 {
                            try? handle.close()
                            let bytes = [UInt8](data)
                            if bytes.count >= 8 && bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70 {
                                mediaType = .video
                            } else if bytes.count >= 4 && bytes[0] == 0x1A && bytes[1] == 0x45 && bytes[2] == 0xDF && bytes[3] == 0xA3 {
                                mediaType = .video
                            } else if bytes.count >= 12 && bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 &&
                                        bytes[8] == 0x41 && bytes[9] == 0x56 && bytes[10] == 0x49 {
                                mediaType = .video
                            }
                        }
                    } else {
                        mediaType = serveURL.isVideo ? .video : .image
                    }
                    
                    return MediaItem(id: UUID(), url: serveURL, type: mediaType, dateAdded: date, pubkey: ownerHex, tags: nil)
                }
            }.value

            await MainActor.run {
                if self.blossomMedia.count != result.count {
                    print("ViewerView: Loaded \(result.count) Blossom media items")
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
        }
        .buttonStyle(.plain)
    }
}

struct NoteRow: View {
    let event: NostrEvent
    @EnvironmentObject var nostrService: NostrService
    
    var cleanContent: String {
        return event.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    var displayName: String {
        if let name = nostrService.profileNames[event.pubkey] {
            return name
        }
        return event.pubkey.prefix(8) + "..." + event.pubkey.suffix(4)
    }
    
    var isOwner: Bool {
        return event.pubkey == nostrService.ownerHexPubkey
    }
    
    var body: some View {
        Button(action: {
            if let url = event.njumpURL {
                NSWorkspace.shared.open(url)
                NSApplication.shared.hide(nil)
            }
        }) {
            VStack(alignment: .leading, spacing: 12) {
                // Header with profile and timestamp
                HStack {
                    if let pictureURL = nostrService.profilePictures[event.pubkey] {
                        CachedAsyncImage(url: pictureURL) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Circle().fill(isOwner ? Color.havenPurple : Color.blue)
                                .overlay(Image(systemName: "person.fill").font(.caption).foregroundColor(.white))
                        }
                        .frame(width: 32, height: 32)
                        .clipShape(Circle())
                    } else {
                        Circle().fill(isOwner ? Color.havenPurple : Color.blue).frame(width: 32, height: 32)
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
                        Image(systemName: isOwner ? "pencil.line" : "tag.fill")
                            .font(.system(size: 10))
                        Text(isOwner ? "Text Note" : "Tagged")
                    }
                    .font(.caption2.bold()).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(isOwner ? Color.havenPurple.opacity(0.15) : Color.blue.opacity(0.15))
                    .foregroundColor(isOwner ? .havenPurple : .blue)
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
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
        .onAppear {
            if nostrService.profileNames[event.pubkey] == nil {
                nostrService.fetchMissingProfiles(for: [event.pubkey])
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
    
    var body: some View {
        ZStack {
            Group {
                // Use item.type instead of url extension checks for Blossom compatibility
                if item.type == .video {
                    VideoThumbnailView(url: item.url)
                        // VideoThumbnailView internally uses .fill and resizable
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if item.url.isGIF {
                    AnimatedImage(url: item.url, contentMode: .fill, shouldAnimate: false, targetSize: CGSize(width: 200, height: 200))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Default to image for non-video items
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
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .contextMenu {
            Button(action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.absoluteString, forType: .string)
            }) {
                Label("Copy Link", systemImage: "doc.on.doc")
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
    @State private var cachedImage: NSImage? = nil
    @State private var isLoading = false
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image = cachedImage {
                    Image(nsImage: image)
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
        if let data = MediaCacheService.shared.loadFromCache(url: url),
           let image = decode(data: data) {
            self.cachedImage = image
            return
        }
        
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
               let image = decode(data: data) {
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
    
    nonisolated private func decode(data: Data) -> NSImage? {
        if let targetSize = targetSize,
           let downsampled = ImageDownsampler.downsample(data: data, maxDimension: max(targetSize.width, targetSize.height)) {
            return downsampled
        }
        return NSImage(data: data)
    }
}

struct VideoThumbnailView: View {
    let url: URL
    @State private var thumbnail: NSImage? = nil
    @State private var isLoading = true
    @State private var id = UUID()
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image = thumbnail {
                    Image(nsImage: image)
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
            // Use localFileURL: returns HTTP URL for local Blossom (to preserve MIME), 
            // and file:// for cached remote media.
            var resolvedURL = MediaCacheService.shared.localFileURL(for: url)
            
            // 2. If not local, download it first
            if resolvedURL == nil && !MediaCacheService.shared.getSource(for: url).isLocal {
                guard let _ = await MediaCacheService.shared.fetchData(url: url) else {
                    await MainActor.run { self.isLoading = false }
                    return
                }
                resolvedURL = MediaCacheService.shared.localFileURL(for: url)
            }
            
            // For AVAsset operations, use the playable URL (symlink if needed) logic
            let playableURL = MediaCacheService.shared.preparePlayableURL(for: url) ?? resolvedURL ?? url
            
            // 3. Generate thumbnail
            let asset = AVAsset(url: playableURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 400, height: 400)
            
            // Use a very early timestamp (0.1s) to support short videos
            let time = CMTime(seconds: 0.1, preferredTimescale: 60)
            
            // AVAssetImageGenerator can sometimes fail if called too quickly after download
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
            
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, _, _ in
                DispatchQueue.main.async {
                    if let image = image {
                        self.thumbnail = NSImage(cgImage: image, size: NSZeroSize)
                    }
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

// MARK: - CachedAsyncImage
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL
    let content: (Image) -> Content
    let placeholder: () -> Placeholder
    
    @State private var cachedImage: NSImage? = nil
    @State private var isLoading = false
    @State private var id = UUID() // Force refresh if URL changes
    
    init(
        url: URL,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
    }
    
    var body: some View {
        ZStack {
            if let nsImage = cachedImage {
                content(Image(nsImage: nsImage))
            } else {
                placeholder()
                    .onAppear {
                        load()
                    }
            }
        }
        .id(url) // Reset state when URL changes
    }
    
    private func load() {
        if isLoading { return }
        
        // 1. Check disk cache synchronously (it's fast enough for main thread usually, or we could dispatch)
        if let data = MediaCacheService.shared.loadFromCache(url: url),
           let image = NSImage(data: data) {
            self.cachedImage = image
            return
        }
        
        // 2. Download if not cached
        isLoading = true
        
        let operation = BlockOperation {
            // Using a simple URLSession task
            let task = URLSession.shared.dataTask(with: url) { data, response, error in
                defer { 
                    DispatchQueue.main.async { self.isLoading = false }
                }
                
                guard let data = data, error == nil,
                      let image = NSImage(data: data) else {
                    return
                }
                
                // Save to cache
                MediaCacheService.shared.saveToCache(url: url, data: data)
                
                // Update UI
                DispatchQueue.main.async {
                    self.cachedImage = image
                }
            }
            task.resume()
        }
        
        // Use the shared queue to avoid thread explosions
        MediaCacheService.shared.downloadQueue.addOperation(operation)
    }
}
