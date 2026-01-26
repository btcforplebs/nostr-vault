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
    
    enum ViewMode {
        case notes
        case media
    }
    
    var filteredNotes: [NostrEvent] {
        let displayableEvents = nostrService.events.filter { event in
            // Only show text notes (kind 1) in the notes view.
            // File metadata (1063) is handled in the Media tab.
            return event.kind == 1
        }
        
        if searchText.isEmpty {
            return displayableEvents
        }
        return displayableEvents.filter { $0.content.localizedCaseInsensitiveContains(searchText) }
    }
    
    var allMediaItems: [MediaItem] {
        var items: [MediaItem] = []
        if relayManager.isRunning {
            items.append(contentsOf: blossomMedia)
        }
        items.append(contentsOf: nostrService.noteMedia)
        
        // Group by URL and pick the latest date for each
        var latestItems: [URL: MediaItem] = [:]
        for item in items {
            if let existing = latestItems[item.url] {
                if item.dateAdded > existing.dateAdded {
                    latestItems[item.url] = item
                }
            } else {
                latestItems[item.url] = item
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
                            loadLocalMedia()
                        }
                    }
                    .padding(4)
                    .background(Color.primary.opacity(0.05))
                    .cornerRadius(24)
                    
                    Spacer()
                    
                    // Connection Status
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        Text(nostrService.connectionStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.trailing, 8)
                    
                    Button(action: {
                        refreshAll()
                    }) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
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
            if !newValue && relayManager.isRunning {
                // Relay finished booting, connect now
                refreshAll()
            }
        }
        .onChange(of: relayManager.isRunning) { oldValue, newValue in
            if newValue && !relayManager.isBooting {
                refreshAll()
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
                    
                    if relayManager.isBooting {
                        VStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Relay is booting...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text(relayManager.isRunning ? "Waiting for incoming events..." : "Start the relay to see notes.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
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
                    Text("Hosted images or images in notes will appear here.")
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
                    
                    if item.url.isVideo {
                        VideoPlayerView(url: item.url)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding()
                    } else if item.url.isGIF {
                        AnimatedImage(url: item.url, contentMode: .fit, shouldAnimate: true)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding()
                    } else if item.url.isImage {
                        RetryableAsyncImage(url: item.url, contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding()
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
        // Use the actual data directory from ConfigService
        let relayDataDir = configService.relayDataDir
        let blossomDir = relayDataDir.appendingPathComponent(configService.config.blossomPath)
        
        do {
            if !FileManager.default.fileExists(atPath: blossomDir.path) {
                try? FileManager.default.createDirectory(at: blossomDir, withIntermediateDirectories: true)
                self.blossomMedia = []
                return
            }
            
            let fileURLs = try FileManager.default.contentsOfDirectory(at: blossomDir, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey])
            let items = fileURLs.compactMap { url -> MediaItem? in
                let filename = url.lastPathComponent
                if filename.starts(with: ".") || filename == "LOCK" { return nil }
                // Use the centralized webURL which handles local vs remote correctly
                guard let serveURL = URL(string: "\(configService.config.webURL)/\(filename)") else { return nil }
                
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                let date = (attributes?[.creationDate] as? Date) ?? (attributes?[.modificationDate] as? Date) ?? Date()
                
                let mediaType: MediaItem.MediaType = serveURL.isVideo ? .video : .image
                return MediaItem(id: UUID(), url: serveURL, type: mediaType, dateAdded: date)
            }
            self.blossomMedia = items
        } catch {
            print("Error loading blossom media: \(error)")
        }
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
            }
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
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with profile and timestamp
            HStack {
                Circle().fill(Color.havenPurple).frame(width: 32, height: 32)
                    .overlay(Image(systemName: "person.fill").font(.caption).foregroundColor(.white))
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.pubkey.prefix(8) + "..." + event.pubkey.suffix(4))
                        .font(.subheadline.bold())
                    Text(timeAgo(from: event.createdAtDate))
                        .font(.caption2).foregroundColor(.secondary)
                }
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "bubble.left")
                    Text(event.kindDescription)
                }
                .font(.caption2).padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.white.opacity(0.1)).cornerRadius(4)
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
                if item.url.isVideo {
                    VideoThumbnailView(url: item.url)
                        // VideoThumbnailView internally uses .fill and resizable
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if item.url.isGIF {
                    AnimatedImage(url: item.url, contentMode: .fill, shouldAnimate: false, targetSize: CGSize(width: 200, height: 200))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if item.url.isImage {
                    RetryableAsyncImage(url: item.url, contentMode: .fill, targetSize: CGSize(width: 200, height: 200))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Fallback using GeometryReader to fill space
                    GeometryReader { geo in
                        ZStack {
                            Rectangle().fill(Color.gray.opacity(0.1))
                            Text(item.url.pathExtension.uppercased())
                                .font(.caption2.bold())
                                .foregroundColor(.secondary)
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
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
        if let data = MediaCacheService.shared.loadFromCache(url: url),
           let image = decode(data: data) {
            self.cachedImage = image
        } else if targetSize != nil {
            // Force manual loading for grid items to ensure we downsample
            autoCache()
        } else if url.host == "127.0.0.1" || url.host == "localhost" {
            // It's local blossom, AsyncImage handles it fine
        } else {
            // Remote and not cached - trigger automatic background cache
            autoCache()
        }
    }
    
    private func autoCache() {
        let downloadRequest = BlockOperation {
            let semaphore = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: url) { data, response, _ in
                if let data = data, let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    MediaCacheService.shared.saveToCache(url: url, data: data)
                    if let image = self.decode(data: data) {
                        DispatchQueue.main.async {
                            self.cachedImage = image
                        }
                    }
                }
                semaphore.signal()
            }.resume()
            semaphore.wait()
        }
        MediaCacheService.shared.downloadQueue.addOperation(downloadRequest)
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
        // Check cache first
        if let cachedData = MediaCacheService.shared.loadFromCache(url: url),
           let image = NSImage(data: cachedData) {
            self.thumbnail = image
            self.isLoading = false
            return
        }
        
        isLoading = true
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 400, height: 400)
        
        let time = CMTime(seconds: 1, preferredTimescale: 60)
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, _, _ in
            DispatchQueue.main.async {
                if let image = image {
                    let nsImage = NSImage(cgImage: image, size: NSZeroSize)
                    self.thumbnail = nsImage
                    
                    // Save to cache
                    if let tiffData = nsImage.tiffRepresentation,
                       let bitmap = NSBitmapImageRep(data: tiffData),
                       let pngData = bitmap.representation(using: .png, properties: [:]) {
                        MediaCacheService.shared.saveToCache(url: self.url, data: pngData)
                    }
                }
                self.isLoading = false
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
