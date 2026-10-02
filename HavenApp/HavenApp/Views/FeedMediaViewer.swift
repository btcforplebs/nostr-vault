import SwiftUI
import AVKit
import CryptoKit
import os.log
#if os(iOS)
import Photos
#endif

struct IdentifiableURL: Identifiable {
    let id = UUID()
    /// The tapped URL — the page the viewer opens on.
    let url: URL
    /// The full set of media in the note this URL came from, in display order.
    /// Defaults to just `[url]` so single-media call sites are unchanged.
    let allURLs: [URL]

    init(url: URL, allURLs: [URL]? = nil) {
        self.url = url
        self.allURLs = (allURLs?.isEmpty == false ? allURLs! : [url])
    }
}

/// Full-screen, swipeable viewer for a note's media. Opens on `selected` and pages
/// horizontally across `urls`, hosting one `FeedMediaViewer` per page (which already
/// yields horizontal drags to a parent `TabView` when not zoomed). On macOS — where
/// `PageTabViewStyle` is unavailable — it falls back to the single tapped item.
struct FeedMediaPager: View {
    let urls: [URL]
    let selected: URL
    var onDismiss: (() -> Void)? = nil

    @State private var selection: URL

    init(urls: [URL], selected: URL, onDismiss: (() -> Void)? = nil) {
        self.urls = urls.isEmpty ? [selected] : urls
        self.selected = selected
        self.onDismiss = onDismiss
        _selection = State(initialValue: selected)
    }

    var body: some View {
        #if os(iOS)
        if urls.count <= 1 {
            FeedMediaViewer(url: selected, onDismiss: onDismiss)
        } else {
            ZStack {
                Color.black.ignoresSafeArea()
                TabView(selection: $selection) {
                    ForEach(urls, id: \.absoluteString) { url in
                        FeedMediaViewer(url: url, enableDragDismiss: true, onDismiss: onDismiss)
                            .tag(url)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .automatic))
                // A PageTabViewStyle TabView needs a definite size or it collapses
                // (renders as a small square and stops paging). Fill the screen like
                // MediaGalleryViewer's pager does.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
            }
        }
        #else
        FeedMediaViewer(url: selected, onDismiss: onDismiss)
        #endif
    }
}

struct FeedMediaViewer: View {
    let url: URL
    var enableDragDismiss: Bool = true
    var onDismiss: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mediaZoomPresented) private var zoomPresented
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    @State private var isVideo: Bool = false
    @State private var isGIF: Bool = false
    @State private var isLoadingType: Bool = true

    @State private var isMirroring: Bool = false
    @State private var mirrorStatus: MirrorStatus? = nil
    /// Whether the user has their own backup of this specific blob — i.e. its sha256
    /// is present in the local relay's Blossom store. Determined by a per-blob check in
    /// `updateMirrorStatus()`, not by the URL's host: media served from a shared public
    /// server the user happens to list as a mirror is NOT their backup.
    @State private var isOnMirror: Bool = false
    @State private var isDeleting: Bool = false
    @State private var deleteStatus: DeleteStatus? = nil
    @State private var isCopied: Bool = false
    @State private var photosSave: PhotosSave = .idle

    enum PhotosSave { case idle, saving, saved }

    enum MirrorStatus {
        case loading
        case success
        case failed(String)
    }

    enum DeleteStatus {
        case loading
        case success
        case failed(String)
    }

    private let logger = Logger(subsystem: "com.bitvora.haven", category: "media-viewer")

    private var blossomService: BlossomService {
        BlossomService(configService: configService, nostrService: nostrService)
    }
    
    var body: some View {
        ZStack {
            Color.black
                .opacity(max(0.1, 1.0 - (abs(offset.height) / 500.0)))
                .ignoresSafeArea()
            
            Group {
                if isLoadingType {
                    ProgressView().tint(.white)
                } else if isVideo {
                    FullScreenVideoPlayer(url: url, onPiPStart: { performDismiss() })
                } else if isGIF {
                    AnimatedImage(url: url, contentMode: .fit, shouldAnimate: true)
                } else {
                    MediaViewerPhoto(url: url)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        let delta = value / lastScale
                        lastScale = value
                        scale *= delta
                    }
                    .onEnded { _ in
                        lastScale = 1.0
                        if scale < 1.0 {
                            withAnimation(Motion.snapBack) {
                                scale = 1.0
                                offset = .zero
                            }
                        }
                    }
            )
            .simultaneousGestureIf(
                enableDragDismiss,
                DragGesture()
                    .onChanged { value in
                        if scale > 1.0 {
                            offset = CGSize(
                                width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height
                            )
                        } else if !zoomPresented {
                            // Swipe to dismiss tracking - ONLY vertical when not zoomed
                            // This allows simultaneous gesture in parent TabView to handle horizontal page swiping.
                            // Under the zoom transition the system swipe does this.
                            offset = CGSize(width: 0, height: value.translation.height)
                        }
                    }
                    .onEnded { value in
                        if scale > 1.0 {
                            lastOffset = offset
                        } else if !zoomPresented {
                            // Check height for dismissal
                            if abs(value.translation.height) > 100 {
                                performDismiss()
                            } else {
                                withAnimation(Motion.snapBack) {
                                    offset = .zero
                                    lastOffset = .zero
                                }
                            }
                        }
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation(Motion.snapBack) {
                    if scale > 1.0 {
                        scale = 1.0
                        offset = .zero
                        lastOffset = .zero
                    } else {
                        scale = 2.0
                    }
                }
            }
            .onAppear {
                detectType()
            }
            
            VStack {
                HStack {
                    if !isLoadingType && !isMirroring {
                        let hash = extractSHA256FromURL()
                        let port = configService.config.relayPort
                        #if os(macOS)
                        let localURL = URL(string: "http://127.0.0.1:\(port)/\(hash)")
                        #else
                        let localURL = URL(string: "https://localhost:\(port)/\(hash)")
                        #endif
                        
                        if let localURL = localURL, configService.hasExternalShareURL(for: localURL) {
                            if isOnMirror {
                                HStack(spacing: 8) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.appSystem(size: 16, weight: .semibold))
                                        Text("Mirrored to Blossom")
                                            .font(.appSystem(size: 12, weight: .bold, design: .rounded))
                                            .lineLimit(1)
                                            .fixedSize()
                                    }
                                    .foregroundColor(.white.opacity(0.95))
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 14)
                                    .background(
                                        Capsule()
                                            .fill(Color(red: 0.2, green: 0.8, blue: 0.6).opacity(0.8))
                                            .overlay(
                                                Capsule()
                                                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
                                            )
                                    )

                                    Button(action: {
                                        let link = getMirroredLink()
                                        PlatformClipboard.copy(link)
                                        withAnimation(Motion.pop) {
                                            isCopied = true
                                        }
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                            withAnimation(Motion.fade) {
                                                isCopied = false
                                            }
                                        }
                                    }) {
                                        HStack(spacing: 6) {
                                            Image(systemName: isCopied ? "checkmark.circle.fill" : "doc.on.doc.fill")
                                                .font(.appSystem(size: 14, weight: .semibold))
                                            Text(isCopied ? "Copied!" : "Copy Link")
                                                .font(.appSystem(size: 12, weight: .bold, design: .rounded))
                                                .lineLimit(1)
                                                .fixedSize()
                                        }
                                        .foregroundColor(.white.opacity(0.95))
                                        .padding(.vertical, 8)
                                        .padding(.horizontal, 14)
                                        .background(
                                            Capsule()
                                                .fill(isCopied ? Color(red: 0.2, green: 0.8, blue: 0.6).opacity(0.8) : Color.white.opacity(0.2))
                                                .overlay(
                                                    Capsule()
                                                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                                                )
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                                .shadow(color: Color.black.opacity(0.3), radius: 4)
                                .padding(20)
                            } else {
                                Button {
                                    mirrorToBlossomTapped()
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "arrow.down.circle.fill")
                                            .font(.appSystem(size: 16, weight: .semibold))
                                        Text("Mirror to Blossom")
                                            .font(.appSystem(size: 12, weight: .bold, design: .rounded))
                                            .lineLimit(1)
                                            .fixedSize()
                                    }
                                    .foregroundColor(.white.opacity(0.95))
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 14)
                                    .background(
                                        Capsule()
                                            .fill(Color.black.opacity(0.6))
                                            .overlay(
                                                Capsule()
                                                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
                                            )
                                    )
                                    .shadow(color: Color.black.opacity(0.3), radius: 4)
                                    .padding(20)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Spacer()
                    Button {
                        performDismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.appSystem(size: 32))
                            .foregroundColor(.white.opacity(0.8))
                            .padding(20)
                            .shadow(radius: 4)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()

                // Bottom-right, not in the top row: a third capsule there
                // squeezed Mirrored / Copy Link into one letter per line.
                #if os(iOS)
                if !isLoadingType && !isDeleting {
                    HStack {
                        Spacer()
                        Button {
                            saveToPhotosTapped()
                        } label: {
                            HStack(spacing: 6) {
                                if photosSave == .saving {
                                    ProgressView().controlSize(.small).tint(.white)
                                } else {
                                    Image(systemName: photosSave == .saved ? "checkmark.circle.fill" : "square.and.arrow.down")
                                        .font(.appSystem(size: 16, weight: .semibold))
                                }
                                Text(photosSave == .saved ? "Saved" : "Save to Photos")
                                    .font(.appSystem(size: 12, weight: .bold, design: .rounded))
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                            .foregroundColor(.white.opacity(0.95))
                            .padding(.vertical, 8)
                            .padding(.horizontal, 14)
                            .background(
                                Capsule()
                                    .fill(photosSave == .saved ? Color(red: 0.2, green: 0.8, blue: 0.6).opacity(0.8) : Color.black.opacity(0.6))
                                    .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
                            )
                            .shadow(color: Color.black.opacity(0.3), radius: 4)
                        }
                        .buttonStyle(.plain)
                        .disabled(photosSave != .idle)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 28)
                }
                #endif

                if !isLoadingType && isDeleting {
                    HStack(spacing: 16) {
                        Button(role: .destructive) {
                            deleteFromMirrorsTapped()
                        } label: {
                            Label("Delete from mirrors", systemImage: "trash")
                        }

                        Button(role: .destructive) {
                            deleteEverywhereTapped()
                        } label: {
                            Label("Delete everywhere", systemImage: "trash.fill")
                        }

                        Spacer()

                        Button("Cancel") {
                            isDeleting = false
                            deleteStatus = nil
                        }
                    }
                    .padding(16)
                    .background(Color.black.opacity(0.8))
                    .cornerRadius(8)
                    .padding(16)
                }
            }
            .onLongPressGesture {
                if !isLoadingType && !isMirroring {
                    withAnimation(Motion.fade) {
                        isDeleting.toggle()
                    }
                }
            }

            if let status = mirrorStatus {
                mirrorStatusView(status)
            }

            if let status = deleteStatus {
                deleteStatusView(status)
            }
        }
        .task(id: url) {
            photosSave = .idle
            updateMirrorStatus()
        }
        #if os(iOS)
        .onAppear {
            AppDelegate.allowLandscape = true
        }
        .onDisappear {
            AppDelegate.allowLandscape = false
            // Force back to portrait when leaving the viewer
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }
        }
        #endif
    }

    private func performDismiss() {
        if let onDismiss = onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }
    
    private func detectType() {
        if let kind = MediaKindResolver.cachedKind(for: url) {
            apply(kind)
            isLoadingType = false
            return
        }
        isLoadingType = true
        Task { @MainActor in
            apply(await MediaKindResolver.kind(for: url))
            isLoadingType = false
        }
    }

    private func apply(_ kind: MediaKind) {
        isVideo = kind == .video
        isGIF = kind == .gif
    }
    
    private var failureView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.appSystem(size: 40))
                .foregroundColor(.orange)
            Text("Failed to load image")
                .foregroundColor(.white)
                .font(.appHeadline)
            Text(url.absoluteString)
                .foregroundColor(.secondary)
                .font(.appCaption)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    #if os(iOS)
    /// Downloads the media as shown and adds it to the Photos library.
    /// A video goes in as a file so Photos keeps it a video.
    private func saveToPhotosTapped() {
        photosSave = .saving
        let mediaURL = url
        let asVideo = isVideo
        Task {
            func fail(_ message: String) async {
                await MainActor.run {
                    photosSave = .idle
                    ErrorNotificationManager.shared.show(message, icon: "exclamationmark.triangle.fill")
                }
            }
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                await fail("Allow Nostr Vault to add to Photos in Settings")
                return
            }
            let session = URLSession(configuration: .default, delegate: LocalhostTrustDelegate(), delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            do {
                let (data, response) = try await session.data(from: mediaURL)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    await fail("Couldn't download the media (HTTP \(http.statusCode))")
                    return
                }
                if asVideo {
                    let ext = mediaURL.pathExtension.isEmpty ? "mp4" : mediaURL.pathExtension
                    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
                    try data.write(to: tempURL)
                    defer { try? FileManager.default.removeItem(at: tempURL) }
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: tempURL, options: nil)
                    }
                } else {
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
                    }
                }
                await MainActor.run { photosSave = .saved }
            } catch {
                logger.error("Save to Photos failed: \(error.localizedDescription)")
                await fail("Couldn't save to Photos")
            }
        }
    }
    #endif

    private func mirrorToBlossomTapped() {
        isMirroring = true
        mirrorStatus = .loading

        Task {
            // Request background execution time on iOS so the mirror completes
            // even if the user dismisses the viewer or switches apps.
            #if os(iOS)
            let bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "BlossomMirror", expirationHandler: nil)
            #endif

            defer {
                #if os(iOS)
                UIApplication.shared.endBackgroundTask(bgTaskId)
                #endif
                isMirroring = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                    withAnimation(Motion.bannerOut) {
                        self.mirrorStatus = nil
                    }
                }
            }

            do {
                let (data, serverContentType) = try await downloadMedia()
                let sha256 = SHA256.hash(data: data)
                let sha256String = sha256.compactMap { String(format: "%02x", $0) }.joined()
                // Prefer the source server's Content-Type — it's the authoritative type from
                // the server where the blob is already playable. Only fall back to guessing
                // (determineContentType) when the server didn't provide one (e.g. cached data).
                let contentType = serverContentType ?? determineContentType()

                let saved = await self.blossomService.saveToLocalRelay(
                    data: data,
                    sha256: sha256String,
                    contentType: contentType
                )
                await MainActor.run {
                    withAnimation(Motion.panel) {
                        if saved {
                            mirrorStatus = .success
                            isOnMirror = true
                        } else {
                            mirrorStatus = .failed("Failed to save to local relay")
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    withAnimation(Motion.panel) {
                        mirrorStatus = .failed(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func deleteFromMirrorsTapped() {
        deleteStatus = .loading

        Task {
            let sha256 = extractSHA256FromURL()
            guard !sha256.isEmpty else {
                await MainActor.run {
                    withAnimation(Motion.panel) {
                        deleteStatus = .failed("Could not extract hash from URL")
                        isDeleting = false
                    }
                }
                return
            }

            let success = await blossomService.deleteFromMirrors(sha256: sha256)
            await MainActor.run {
                withAnimation(Motion.panel) {
                    deleteStatus = success ? .success : .failed("Failed to delete from mirrors")
                    isDeleting = false
                    if success {
                        isOnMirror = false
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    withAnimation(Motion.bannerOut) {
                        self.deleteStatus = nil
                    }
                }
            }
        }
    }

    private func deleteEverywhereTapped() {
        deleteStatus = .loading

        Task {
            let sha256 = extractSHA256FromURL()
            guard !sha256.isEmpty else {
                await MainActor.run {
                    withAnimation(Motion.panel) {
                        deleteStatus = .failed("Could not extract hash from URL")
                        isDeleting = false
                    }
                }
                return
            }

            let localSuccess = await blossomService.deleteFromLocal(sha256: sha256)
            let mirrorsSuccess = await blossomService.deleteFromMirrors(sha256: sha256)

            await MainActor.run {
                withAnimation(Motion.panel) {
                    if localSuccess && mirrorsSuccess {
                        deleteStatus = .success
                        isOnMirror = false
                    } else if localSuccess {
                        deleteStatus = .failed("Deleted locally, mirror deletion failed")
                        isOnMirror = false
                    } else if mirrorsSuccess {
                        deleteStatus = .failed("Deleted from mirrors, local failed")
                    } else {
                        deleteStatus = .failed("Failed to delete")
                    }
                    isDeleting = false
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation(Motion.bannerOut) {
                        self.deleteStatus = nil
                        self.performDismiss()
                    }
                }
            }
        }
    }

    private func extractSHA256FromURL() -> String {
        let urlString = url.absoluteString
        let lastComponent = url.lastPathComponent
        if lastComponent.count == 64 && lastComponent.allSatisfy({ $0.isHexDigit }) {
            return lastComponent
        }
        let pattern = "[a-f0-9]{64}"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: urlString, options: [], range: NSRange(urlString.startIndex..., in: urlString)),
           let range = Range(match.range, in: urlString) {
            return String(urlString[range]).lowercased()
        }
        return url.deletingPathExtension().lastPathComponent
    }

    private func getMirroredLink() -> String {
        // If the current URL is already on a known external Blossom mirror, use it directly
        if let host = url.host?.lowercased() {
            let isLocal = host == "127.0.0.1" || host == "localhost" || host == "0.0.0.0"
            if !isLocal {
                let mirrorHosts: Set<String> = Set(
                    configService.config.activeBlossomMirrors.compactMap {
                        URL(string: $0)?.host?.lowercased()
                    }
                )
                if mirrorHosts.contains(host) {
                    return url.absoluteString
                }
            }
        }

        // For local URLs, rewrite to an external shareable URL
        let hash = extractSHA256FromURL()
        if !hash.isEmpty {
            let port = configService.config.relayPort
            #if os(macOS)
            let localURL = URL(string: "http://127.0.0.1:\(port)/\(hash)")!
            #else
            let localURL = URL(string: "https://localhost:\(port)/\(hash)")!
            #endif
            return configService.externalShareURL(for: localURL).absoluteString
        }
        return url.absoluteString
    }

    /// Recomputes whether the user has their own backup of this blob — i.e. its sha256
    /// is present in the local relay's Blossom store. Replaces the old host-matching
    /// heuristic, which falsely flagged any media served from a host that also happened
    /// to be a configured mirror (e.g. the default cdn.satellite.earth) as "mirrored"
    /// even when the user had never mirrored it. A blob living on a shared public server
    /// is not the user's backup, so only a copy in the local store counts here.
    private func updateMirrorStatus() {
        let hash = extractSHA256FromURL()
        guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else {
            isOnMirror = false
            return
        }

        let fileURL = configService.relayDataDir
            .appendingPathComponent(configService.config.blossomPath)
            .appendingPathComponent(hash)
        isOnMirror = FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Downloads media data and returns it along with the server's Content-Type (if available).
    /// Preserving the source server's Content-Type is critical for mirroring — it's the only
    /// reliable way to transfer format metadata since the khatru magic library can't detect MP4/MOV.
    private func downloadMedia() async throws -> (Data, String?) {
        // 1. If it's already a local file URL, load it directly. Map instead of
        // reading into the heap — mirror/save paths pass whole videos through here.
        if url.isFileURL {
            return (try Data(contentsOf: url, options: .mappedIfSafe), nil)
        }

        // 2. Try fetching via MediaCacheService which handles caching & localhost self-signed SSL/TLS issues
        if let cachedData = await MediaCacheService.shared.fetchData(url: url) {
            return (cachedData, nil)
        }

        // 3. Fallback to standard network request if cache fetch returns nil (e.g. uncached remote resource)
        var request = URLRequest(url: url)
        request.timeoutInterval = 120  // 2 minutes — 30s was too short for video files

        let (data, response) = try await URLSession.shared.data(for: request)

        // If it's a file URL (e.g. resolved asynchronously later), it won't have an HTTPURLResponse
        if let httpResponse = response as? HTTPURLResponse {
            guard (200...299).contains(httpResponse.statusCode) else {
                let status = httpResponse.statusCode
                let mediaType = isVideo ? "video" : isGIF ? "GIF" : "image"
                throw NSError(domain: "DownloadError", code: status, userInfo: [NSLocalizedDescriptionKey: "Failed to download \(mediaType): HTTP \(status)"])
            }
            return (data, httpResponse.mimeType)
        }

        return (data, nil)
    }

    private func determineContentType() -> String {
        let ext = url.pathExtension.lowercased()
        if let mime = SupportedMediaFormats.mime(forExtension: ext) {
            return mime
        }
        // Use the actual detected content type from the HEAD-based detector when available.
        // This is critical for hash-based Blossom URLs (no extension) — without it the
        // server's magic library can't identify MP4/MOV and falls back to whatever we send.
        if let detected = MediaTypeDetector.shared.getCachedContentType(for: url) {
            // Strip parameters (e.g. "video/mp4; codecs=avc1" → "video/mp4")
            let base = detected.split(separator: ";").first.map(String.init) ?? detected
            return base.trimmingCharacters(in: .whitespaces)
        }
        // Fallback defaults
        if isVideo { return "video/mp4" }
        if isGIF   { return "image/gif" }
        return "image/jpeg"
    }

    @ViewBuilder
    private func mirrorStatusView(_ status: MirrorStatus) -> some View {
        VStack {
            switch status {
            case .loading:
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(.white)
                    Text("Mirroring to Blossom...")
                        .font(.appSystem(size: 14, weight: .semibold))
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(Capsule().fill(Color.blue.opacity(0.85)))
                .foregroundColor(.white)

            case .success:
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.appSystem(size: 14, weight: .semibold))
                    Text("Mirrored to Blossom")
                        .font(.appSystem(size: 14, weight: .semibold))
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(Capsule().fill(Color(red: 0.2, green: 0.8, blue: 0.6)))
                .foregroundColor(.white)

            case .failed(let message):
                HStack(spacing: 8) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.appSystem(size: 14, weight: .semibold))
                    Text(message)
                        .font(.appSystem(size: 13, weight: .semibold))
                        .lineLimit(2)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(Capsule().fill(Color.red.opacity(0.8)))
                .foregroundColor(.white)
            }
        }
        .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)
        .transition(.asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .opacity
        ))
    }

    @ViewBuilder
    private func deleteStatusView(_ status: DeleteStatus) -> some View {
        VStack {
            switch status {
            case .loading:
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(.white)
                    Text("Deleting...")
                        .font(.appSystem(size: 14, weight: .semibold))
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(Capsule().fill(Color.red.opacity(0.85)))
                .foregroundColor(.white)

            case .success:
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.appSystem(size: 14, weight: .semibold))
                    Text("Deleted")
                        .font(.appSystem(size: 14, weight: .semibold))
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(Capsule().fill(Color(red: 0.8, green: 0.2, blue: 0.2)))
                .foregroundColor(.white)

            case .failed(let message):
                HStack(spacing: 8) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.appSystem(size: 14, weight: .semibold))
                    Text(message)
                        .font(.appSystem(size: 13, weight: .semibold))
                        .lineLimit(2)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(Capsule().fill(Color.red.opacity(0.8)))
                .foregroundColor(.white)
            }
        }
        .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)
        .transition(.asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .opacity
        ))
    }
}

// MARK: - MediaViewerPhoto

/// Cached photo view for the full-screen media viewer.
/// Uses MediaCacheService instead of AsyncImage to avoid re-downloads.
struct MediaViewerPhoto: View {
    let url: URL
    @State private var image: PlatformImage?
    @State private var loadFailed = false

    var body: some View {
        ZStack {
            if let image = image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFit()
            } else if loadFailed {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.appSystem(size: 40))
                        .foregroundColor(.orange)
                    Text("Failed to load image")
                        .foregroundColor(.white)
                        .font(.appHeadline)
                    Text(url.absoluteString)
                        .foregroundColor(.secondary)
                        .font(.appCaption)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            } else {
                ProgressView().tint(.white)
            }
        }
        .onAppear { loadImage() }
    }

    private func loadImage() {
        guard image == nil, !loadFailed else { return }
        Task {
            guard let data = await MediaCacheService.shared.fetchData(url: url) else {
                await MainActor.run { self.loadFailed = true }
                return
            }
            // Screen-bounded decode: the pager keeps neighbor pages alive, so
            // full-resolution originals (50-190 MB decoded) stack up fast.
            let downsampled = await ImageDownsampler.downsampleToScreen(data: data)
            if let img = downsampled ?? PlatformImage(data: data) {
                await MainActor.run { self.image = img }
            } else {
                await MainActor.run { self.loadFailed = true }
            }
        }
    }
}

extension View {
    @ViewBuilder
    func simultaneousGestureIf<T: Gesture>(_ enabled: Bool, _ gesture: T) -> some View {
        if enabled {
            self.simultaneousGesture(gesture)
        } else {
            self
        }
    }
}

// MARK: - Zoom presentation

/// Namespace the tapped thumbnail and the full-screen viewer share, so the
/// viewer grows out of the photo's spot on screen and shrinks back into it.
private struct MediaZoomNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

/// True inside a viewer presented with the zoom transition: the system then
/// owns swipe-down-to-dismiss, so the viewer's own drag must not fight it.
private struct MediaZoomPresentedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var mediaZoomNamespace: Namespace.ID? {
        get { self[MediaZoomNamespaceKey.self] }
        set { self[MediaZoomNamespaceKey.self] = newValue }
    }
    var mediaZoomPresented: Bool {
        get { self[MediaZoomPresentedKey.self] }
        set { self[MediaZoomPresentedKey.self] = newValue }
    }
}

extension View {
    /// Marks a tappable thumbnail as the place the viewer zooms out of.
    @ViewBuilder
    func mediaZoomSource(_ url: URL, namespace: Namespace.ID?) -> some View {
        #if os(iOS)
        if #available(iOS 18.0, *), let namespace {
            self.matchedTransitionSource(id: url.absoluteString, in: namespace)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Presents the media viewer for `item`. On iOS 18+ it zooms out of the
    /// tapped photo and swipes back down into it; earlier iOS and macOS keep
    /// the sheet.
    func mediaViewer(item: Binding<IdentifiableURL?>, namespace: Namespace.ID) -> some View {
        modifier(MediaViewerPresentation(item: item, namespace: namespace))
    }
}

private struct MediaViewerPresentation: ViewModifier {
    @Binding var item: IdentifiableURL?
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 18.0, *) {
            content
                .environment(\.mediaZoomNamespace, namespace)
                .fullScreenCover(item: $item) { media in
                    FeedMediaPager(urls: media.allURLs, selected: media.url, onDismiss: { item = nil })
                        .environment(\.mediaZoomPresented, true)
                        .navigationTransition(.zoom(sourceID: media.url.absoluteString, in: namespace))
                }
        } else {
            sheetFallback(content)
        }
        #else
        sheetFallback(content)
        #endif
    }

    private func sheetFallback(_ content: Content) -> some View {
        content.sheet(item: $item) { media in
            FeedMediaPager(urls: media.allURLs, selected: media.url, onDismiss: { item = nil })
        }
    }
}
