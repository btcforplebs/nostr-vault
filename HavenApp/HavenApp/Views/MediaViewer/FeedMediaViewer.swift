import SwiftUI
import AVKit
import CryptoKit
import os.log
#if os(iOS)
import Photos
#endif

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

    @State var isVideo: Bool = false
    @State var isGIF: Bool = false
    @State var isLoadingType: Bool = true
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

    @State var isMirroring: Bool = false
    @State var mirrorStatus: MirrorStatus? = nil
    /// Whether the user has their own backup of this specific blob — i.e. its sha256
    /// is present in the local relay's Blossom store. Determined by a per-blob check in
    /// `updateMirrorStatus()`, not by the URL's host: media served from a shared public
    /// server the user happens to list as a mirror is NOT their backup.
    @State var isOnMirror: Bool = false
    @State var isDeleting: Bool = false
    @State private var pendingDelete: MediaDeleteScope?
    @State var deleteStatus: DeleteStatus? = nil
    @State var isCopied: Bool = false
    @State var photosSave: PhotosSave = .idle

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

    var blossomService: BlossomService {
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
                            Label("Delete from media servers", systemImage: "trash")
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
        .confirmMediaDelete($pendingDelete, hash: extractSHA256FromURL()) { scope in
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

    func performDismiss() {
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
    func saveToPhotosTapped() {
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
}
