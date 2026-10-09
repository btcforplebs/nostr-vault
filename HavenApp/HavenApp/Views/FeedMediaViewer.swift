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
    /// The page now showing, so the zoom can close into that photo's spot.
    var onPage: ((URL) -> Void)? = nil

    @State private var selection: URL
    @Environment(\.mediaZoomPresented) private var zoomPresented

    init(urls: [URL], selected: URL, onDismiss: (() -> Void)? = nil, onPage: ((URL) -> Void)? = nil) {
        self.urls = urls.isEmpty ? [selected] : urls
        self.selected = selected
        self.onDismiss = onDismiss
        self.onPage = onPage
        _selection = State(initialValue: selected)
    }

    var body: some View {
        #if os(iOS)
        if urls.count <= 1 {
            FeedMediaViewer(url: selected, onDismiss: onDismiss)
        } else {
            ZStack {
                // Each page draws its own black, which fades as it is pulled
                // away; a fixed black here would hide the post behind it.
                if !zoomPresented { Color.black.ignoresSafeArea() }
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
                .onChange(of: selection) { _, page in onPage?(page) }
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
    /// Set as the swipe lets go to close: the photo glides home while the
    /// black and the buttons stay gone, instead of coming back as `offset`
    /// animates to zero.
    @State private var isClosing = false

    init(url: URL, enableDragDismiss: Bool = true, onDismiss: (() -> Void)? = nil) {
        self.url = url
        self.enableDragDismiss = enableDragDismiss
        self.onDismiss = onDismiss
        // A kind the feed already resolved is known before the first frame,
        // so the zoom never catches a spinner.
        if let kind = MediaKindResolver.cachedKind(for: url) {
            _isVideo = State(initialValue: kind == .video)
            _isGIF = State(initialValue: kind == .gif)
            _isLoadingType = State(initialValue: false)
        }
    }

    @State private var isMirroring: Bool = false
    @State private var mirrorStatus: MirrorStatus? = nil
    /// Whether the user has their own backup of this specific blob — i.e. its sha256
    /// is present in the local relay's Blossom store. Determined by a per-blob check in
    /// `updateMirrorStatus()`, not by the URL's host: media served from a shared public
    /// server the user happens to list as a mirror is NOT their backup.
    @State private var isOnMirror: Bool = false
    @State private var isDeleting: Bool = false
    @State private var pendingDelete: MediaDeleteScope?
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
    
    /// Under the zoom, the system's own swipe-down moves the photo; this
    /// reports how far it has been pulled.
    @StateObject private var zoomSwipe = ZoomSwipeWatch()

    /// The photo shrinks as you pull it down, so it reads as being put back.
    private var dragShrink: CGFloat {
        scale > 1 ? 1 : max(0.6, 1 - abs(offset.height) / 900)
    }

    private var controlsOpacity: Double {
        if isClosing { return 0 }
        if zoomPresented { return max(0, 1 - abs(zoomSwipe.pull) / 60) }
        return scale > 1 ? 1 : max(0, 1 - abs(offset.height) / 150)
    }

    private var backdropOpacity: Double {
        if isClosing { return 0 }
        // The black goes first, so only the photo travels into the post.
        if zoomPresented { return max(0, 1 - abs(zoomSwipe.pull) / 120) }
        return max(0.1, 1.0 - (abs(offset.height) / 500.0))
    }

    /// Which way a drag at rest scale is going, decided on its first ~10pt
    /// and kept: a sideways page swipe that drifts must not move the photo.
    private enum DragAxis { case undecided, vertical, horizontal }
    @State private var dragAxis: DragAxis = .undecided

    var body: some View {
        ZStack {
            Color.black
                // Under the zoom the cover is see-through, so the post shows
                // through as you pull the photo away.
                .opacity(backdropOpacity)
                .ignoresSafeArea()
                .background { if zoomPresented { ZoomSwipeProbe(watch: zoomSwipe) } }
            
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
            .scaleEffect(scale * dragShrink)
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
            // Under the zoom the system's swipe-down closes the viewer and
            // carries the photo into its spot in one motion. A drag here
            // stops that swipe from starting, so it only pans a zoomed-in
            // photo.
            .simultaneousGestureIf(
                enableDragDismiss && (!zoomPresented || scale > 1),
                DragGesture()
                    .onChanged { value in
                        if scale > 1.0 {
                            offset = CGSize(
                                width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height
                            )
                        } else {
                            // Swipe to dismiss tracking - ONLY vertical when not zoomed
                            // This allows simultaneous gesture in parent TabView to handle horizontal page swiping.
                            let t = value.translation
                            if dragAxis == .undecided, hypot(t.width, t.height) > 10 {
                                dragAxis = abs(t.height) > abs(t.width) ? .vertical : .horizontal
                            }
                            if dragAxis == .vertical {
                                offset = CGSize(width: 0, height: t.height)
                            }
                        }
                    }
                    .onEnded { value in
                        defer { dragAxis = .undecided }
                        if scale > 1.0 {
                            lastOffset = offset
                        } else if dragAxis == .vertical {
                            // Close when it is pulled far enough, or flicked
                            // on in the same direction — pulling down and
                            // pushing back up does not close it.
                            let pulled = value.translation.height
                            let carried = value.predictedEndTranslation.height
                            let sameWay = (pulled >= 0) == (carried >= 0)
                            if sameWay && (abs(pulled) > 100 || abs(carried) > 260) {
                                withAnimation(.smooth(duration: 0.3)) {
                                    isClosing = true
                                }
                                performDismiss()
                            } else {
                                // Spring back carrying the finger's speed.
                                // initialVelocity is in "whole distance per
                                // second" toward zero, so divide by the signed
                                // distance still to travel.
                                let distance = offset.height == 0 ? 1 : offset.height
                                let release = -value.velocity.height / distance
                                withAnimation(.interpolatingSpring(stiffness: 260, damping: 26, initialVelocity: release)) {
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
                    // Short labels, and icons only when even those don't fit
                    // (larger text, narrow phones): a squeezed capsule wraps
                    // its label one letter per line.
                    ViewThatFits(in: .horizontal) {
                        topActions(showLabels: true)
                        topActions(showLabels: false)
                    }
                    .padding(.leading, 16)
                    .padding(.vertical, 20)
                    Spacer()
                    Button {
                        performDismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.appSystem(size: 32))
                            .foregroundColor(.white.opacity(0.8))
                            .padding(.vertical, 20)
                            .padding(.horizontal, 16)
                            .shadow(radius: 4)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()

                if !isLoadingType && isDeleting {
                    HStack(spacing: 16) {
                        Button(role: .destructive) {
                            pendingDelete = .mirrors
                        } label: {
                            Label("Delete from mirrors", systemImage: "trash")
                        }

                        Button(role: .destructive) {
                            pendingDelete = .everywhere
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
            // The buttons get out of the way as soon as you pull, like Photos.
            .opacity(controlsOpacity)
            .allowsHitTesting(offset == .zero || scale > 1.0)
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
        .confirmMediaDelete($pendingDelete) { scope in
            switch scope {
            case .mirrors: deleteFromMirrorsTapped()
            case .everywhere: deleteEverywhereTapped()
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

    // MARK: - Top-row actions

    private static let doneGreen = Color(red: 0.2, green: 0.8, blue: 0.6).opacity(0.8)

    /// Save, then Mirror (or Mirrored + Copy). Labels drop out when
    /// [showLabels] is false, leaving the icon in each capsule.
    @ViewBuilder
    private func topActions(showLabels: Bool) -> some View {
        HStack(spacing: 6) {
            #if os(iOS)
            if !isLoadingType && !isDeleting {
                Button {
                    saveToPhotosTapped()
                } label: {
                    actionCapsule(
                        icon: photosSave == .saved ? "checkmark.circle.fill" : "square.and.arrow.down",
                        label: photosSave == .saved ? "Saved" : "Save",
                        showLabel: showLabels,
                        fill: photosSave == .saved ? Self.doneGreen : Color.black.opacity(0.6),
                        busy: photosSave == .saving
                    )
                }
                .buttonStyle(.plain)
                .disabled(photosSave != .idle)
                .accessibilityLabel(photosSave == .saved ? "Saved to Photos" : "Save to Photos")
            }
            #endif
            if !isLoadingType && !isMirroring, let localURL = viewerLocalURL(),
               configService.hasExternalShareURL(for: localURL) {
                if isOnMirror {
                    actionCapsule(icon: "checkmark.circle.fill", label: "Mirrored", showLabel: showLabels, fill: Self.doneGreen)
                        .accessibilityLabel("Mirrored to Blossom")
                    Button {
                        PlatformClipboard.copy(getMirroredLink())
                        withAnimation(Motion.pop) { isCopied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            withAnimation(Motion.fade) { isCopied = false }
                        }
                    } label: {
                        actionCapsule(
                            icon: isCopied ? "checkmark.circle.fill" : "doc.on.doc.fill",
                            label: isCopied ? "Copied" : "Copy",
                            showLabel: showLabels,
                            fill: isCopied ? Self.doneGreen : Color.white.opacity(0.2)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isCopied ? "Link copied" : "Copy link")
                } else {
                    Button {
                        mirrorToBlossomTapped()
                    } label: {
                        actionCapsule(icon: "arrow.down.circle.fill", label: "Mirror", showLabel: showLabels, fill: Color.black.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Mirror to Blossom")
                }
            }
        }
        .shadow(color: Color.black.opacity(0.3), radius: 4)
    }

    private func actionCapsule(icon: String, label: String, showLabel: Bool, fill: Color, busy: Bool = false) -> some View {
        HStack(spacing: 5) {
            if busy {
                ProgressView().controlSize(.small).tint(.white)
            } else {
                Image(systemName: icon)
                    .font(.appSystem(size: 15, weight: .semibold))
            }
            if showLabel {
                Text(label)
                    .font(.appSystem(size: 12, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .foregroundColor(.white.opacity(0.95))
        .padding(.vertical, 8)
        .padding(.horizontal, showLabel ? 11 : 9)
        .background(
            Capsule()
                .fill(fill)
                .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
        )
    }

    /// The vault's own URL for this blob, which is what the mirror check keys on.
    private func viewerLocalURL() -> URL? {
        let hash = extractSHA256FromURL()
        let port = configService.config.relayPort
        #if os(macOS)
        return URL(string: "http://127.0.0.1:\(port)/\(hash)")
        #else
        return URL(string: "https://localhost:\(port)/\(hash)")
        #endif
    }

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

            let report = await blossomService.deleteFromMirrorsReport(sha256: sha256)
            await MainActor.run {
                withAnimation(Motion.panel) {
                    if report.allDeleted {
                        deleteStatus = .success
                    } else if report.failed.isEmpty {
                        deleteStatus = .failed("No mirrors to delete from")
                    } else {
                        deleteStatus = .failed("Still on " + ListFormatter.localizedString(byJoining: report.failedHosts))
                    }
                    isDeleting = false
                }
                // A failure stays up until tapped, so it can't be missed.
                guard report.allDeleted else { return }
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
            let report = await blossomService.deleteFromMirrorsReport(sha256: sha256)
            let leftover = BlossomService.deleteEverywhereLeftover(localDeleted: localSuccess, mirrors: report)

            await MainActor.run {
                withAnimation(Motion.panel) {
                    deleteStatus = leftover.map { .failed($0) } ?? .success
                    if localSuccess { isOnMirror = false }
                    isDeleting = false
                }
                // A partial delete keeps the viewer and its banner open until
                // the banner is tapped; closing after 2 s hid the failure.
                guard leftover == nil else { return }
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
                Button {
                    withAnimation(Motion.bannerOut) { deleteStatus = nil }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.appSystem(size: 14, weight: .semibold))
                        Text(message)
                            .font(.appSystem(size: 13, weight: .semibold))
                            .multilineTextAlignment(.leading)
                            .lineLimit(3)
                        Image(systemName: "xmark")
                            .font(.appSystem(size: 11, weight: .bold))
                            .opacity(0.7)
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 16)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.red.opacity(0.8)))
                    .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Dismiss")
                .padding(.horizontal, 24)
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
                Button {
                    withAnimation(Motion.bannerOut) { deleteStatus = nil }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.appSystem(size: 14, weight: .semibold))
                        Text(message)
                            .font(.appSystem(size: 13, weight: .semibold))
                            .multilineTextAlignment(.leading)
                            .lineLimit(3)
                        Image(systemName: "xmark")
                            .font(.appSystem(size: 11, weight: .bold))
                            .opacity(0.7)
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 16)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.red.opacity(0.8)))
                    .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Dismiss")
                .padding(.horizontal, 24)
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
    /// Starts with the copy the feed already decoded, so the zoom grows out
    /// of the photo rather than an empty frame; the full-size one replaces it
    /// once loaded.
    @State private var image: PlatformImage?
    @State private var loadFailed = false
    @State private var loadedFull = false

    init(url: URL) {
        self.url = url
        _image = State(initialValue: MediaCacheService.shared.cachedImage(for: url))
    }

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
        guard !loadedFull, !loadFailed else { return }
        Task {
            guard let data = await MediaCacheService.shared.fetchData(url: url) else {
                // Keep the feed's copy on screen if there is one.
                await MainActor.run { if self.image == nil { self.loadFailed = true } }
                return
            }
            // Screen-bounded decode: the pager keeps neighbor pages alive, so
            // full-resolution originals (50-190 MB decoded) stack up fast.
            let downsampled = await ImageDownsampler.downsampleToScreen(data: data)
            if let img = downsampled ?? PlatformImage(data: data) {
                await MainActor.run { self.image = img; self.loadedFull = true }
            } else {
                await MainActor.run { if self.image == nil { self.loadFailed = true } }
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

/// Follows the zoom transition's swipe-down on the presented viewer, so the
/// black and the buttons can fade with it. Once the finger lifts, `pull`
/// returns to zero only if the swipe put the viewer back; on a close it
/// holds, or the black would come back during the flight into the post.
final class ZoomSwipeWatch: NSObject, ObservableObject {
    @Published private(set) var pull: CGFloat = 0

    #if os(iOS)
    private weak var swipe: UIGestureRecognizer?

    /// UIKit's name for the zoom transition's swipe-down recognizer. If a
    /// later iOS renames it, the swipe still closes the viewer; only the
    /// fade is lost.
    private static let swipeName = "com.apple.UIKit.ZoomInteractiveDismissSwipeDown"

    // Each page of a pager attaches to the same recognizer, and pages come
    // and go while the cover stays up.
    deinit { swipe?.removeTarget(self, action: nil) }

    func attach(from view: UIView) {
        guard swipe == nil else { return }
        var ancestor: UIView? = view
        while let v = ancestor {
            if let g = v.gestureRecognizers?.first(where: { $0.name == Self.swipeName }) {
                g.addTarget(self, action: #selector(track(_:)))
                swipe = g
                return
            }
            ancestor = v.superview
        }
    }

    @objc private func track(_ g: UIGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            if let pan = g as? UIPanGestureRecognizer {
                pull = pan.translation(in: nil).y
            }
        case .ended, .cancelled, .failed:
            settle(from: g.view)
        default:
            break
        }
    }

    private func settle(from view: UIView?) {
        var responder: UIResponder? = view
        while let r = responder, !(r is UIViewController) { responder = r.next }
        guard var controller = responder as? UIViewController else { return restore() }
        while let parent = controller.parent { controller = parent }
        guard controller.isBeingDismissed, let coordinator = controller.transitionCoordinator else {
            return restore()
        }
        if coordinator.isInteractive {
            coordinator.notifyWhenInteractionChanges { [weak self] in
                if $0.isCancelled { self?.restore() }
            }
        } else if coordinator.isCancelled {
            restore()
        }
    }

    private func restore() {
        guard pull != 0 else { return }
        withAnimation(Motion.snapBack) { pull = 0 }
    }
    #endif
}

#if os(iOS)
/// Finds the zoom's swipe-down once the viewer is on screen.
private struct ZoomSwipeProbe: UIViewRepresentable {
    let watch: ZoomSwipeWatch

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.watch = watch
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {}

    final class ProbeView: UIView {
        weak var watch: ZoomSwipeWatch?
        // The presentation may install the swipe after this view joins the
        // window, so look again on layout until it is found.
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { watch?.attach(from: self) }
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            if window != nil { watch?.attach(from: self) }
        }
    }
}
#else
private struct ZoomSwipeProbe: View {
    let watch: ZoomSwipeWatch
    var body: some View { EmptyView() }
}
#endif

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
    /// The photo the open viewer is showing. An inline carousel holding it
    /// turns to it, so the zoom closes into a photo that is on screen.
    var mediaViewerPage: URL? {
        get { self[MediaViewerPageKey.self] }
        set { self[MediaViewerPageKey.self] = newValue }
    }
}

private struct MediaViewerPageKey: EnvironmentKey {
    static let defaultValue: URL? = nil
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
    /// The page swiped to in the viewer; nil until the first swipe.
    @State private var page: URL?

    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 18.0, *) {
            content
                .environment(\.mediaZoomNamespace, namespace)
                .environment(\.mediaViewerPage, item == nil ? nil : page)
                .fullScreenCover(item: $item, onDismiss: { page = nil }) { media in
                    FeedMediaPager(urls: media.allURLs, selected: media.url, onDismiss: { item = nil }, onPage: { page = $0 })
                        .environment(\.mediaZoomPresented, true)
                        .presentationBackground(.clear)
                        // Close into the photo on screen, not the one tapped.
                        .navigationTransition(.zoom(sourceID: (page ?? media.url).absoluteString, in: namespace))
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
