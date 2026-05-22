import SwiftUI
import AVKit
import CryptoKit
import os.log

struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}

struct FeedMediaViewer: View {
    let url: URL
    var onDismiss: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
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
    @State private var isDeleting: Bool = false
    @State private var deleteStatus: DeleteStatus? = nil

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
                    VideoPlayerView(url: url)
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
                            withAnimation(.spring()) {
                                scale = 1.0
                                offset = .zero
                            }
                        }
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        if scale > 1.0 {
                            offset = CGSize(
                                width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height
                            )
                        } else {
                            // Swipe to dismiss tracking
                            offset = value.translation
                        }
                    }
                    .onEnded { value in
                        if scale > 1.0 {
                            lastOffset = offset
                        } else {
                            // Check height for dismissal
                            if abs(value.translation.height) > 100 {
                                performDismiss()
                            } else {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    offset = .zero
                                    lastOffset = .zero
                                }
                            }
                        }
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation(.spring()) {
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
                        Button {
                            mirrorToBlossomTapped()
                        } label: {
                            Image(systemName: "square.and.arrow.up.circle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(.white.opacity(0.9))
                                .padding(20)
                                .shadow(radius: 4)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    Button {
                        performDismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.white.opacity(0.8))
                            .padding(20)
                            .shadow(radius: 4)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()

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
                    withAnimation(.easeInOut(duration: 0.2)) {
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
    }
    
    private func performDismiss() {
        if let onDismiss = onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }
    
    private func detectType() {
        let ext = url.pathExtension.lowercased()
        if ["mp4", "mov", "webm", "m4v", "hevc", "h265"].contains(ext) {
            isVideo = true
            isLoadingType = false
        } else if ext == "gif" {
            isGIF = true
            isLoadingType = false
        } else if ["jpg", "jpeg", "png", "webp", "avif", "heic"].contains(ext) {
            isVideo = false
            isGIF = false
            isLoadingType = false
        } else if let cached = MediaTypeDetector.shared.getCachedContentType(for: url) {
            isVideo = MediaTypeDetector.shared.isVideoContentType(cached)
            isGIF = MediaTypeDetector.shared.isGIFContentType(cached)
            isLoadingType = false
        } else {
            isLoadingType = true
            MediaTypeDetector.shared.detectContentType(for: url) { detectedType in
                if let detectedType = detectedType {
                    self.isVideo = MediaTypeDetector.shared.isVideoContentType(detectedType)
                    self.isGIF = MediaTypeDetector.shared.isGIFContentType(detectedType)
                } else {
                    self.isVideo = false
                    self.isGIF = false
                }
                self.isLoadingType = false
            }
        }
    }
    
    private var failureView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundColor(.orange)
            Text("Failed to load image")
                .foregroundColor(.white)
                .font(.headline)
            Text(url.absoluteString)
                .foregroundColor(.secondary)
                .font(.caption)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    private func mirrorToBlossomTapped() {
        isMirroring = true
        mirrorStatus = .loading

        Task {
            defer {
                isMirroring = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                    withAnimation(.easeOut(duration: 0.4)) {
                        self.mirrorStatus = nil
                    }
                }
            }

            do {
                let data = try await downloadMedia()
                let sha256 = SHA256.hash(data: data)
                let sha256String = sha256.compactMap { String(format: "%02x", $0) }.joined()
                let contentType = determineContentType()

                if let _ = await self.blossomService.uploadAndMirror(
                    data: data,
                    sha256: sha256String,
                    contentType: contentType
                ) {
                    await MainActor.run {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            mirrorStatus = .success
                        }
                    }
                } else {
                    await MainActor.run {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            mirrorStatus = .failed("Failed to mirror to Blossom")
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
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
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        deleteStatus = .failed("Could not extract hash from URL")
                        isDeleting = false
                    }
                }
                return
            }

            let success = await blossomService.deleteFromMirrors(sha256: sha256)
            await MainActor.run {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    deleteStatus = success ? .success : .failed("Failed to delete from mirrors")
                    isDeleting = false
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    withAnimation(.easeOut(duration: 0.4)) {
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
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        deleteStatus = .failed("Could not extract hash from URL")
                        isDeleting = false
                    }
                }
                return
            }

            let localSuccess = await blossomService.deleteFromLocal(sha256: sha256)
            let mirrorsSuccess = await blossomService.deleteFromMirrors(sha256: sha256)

            await MainActor.run {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    if localSuccess || mirrorsSuccess {
                        deleteStatus = .success
                    } else {
                        deleteStatus = .failed("Failed to delete media")
                    }
                    isDeleting = false
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation(.easeOut(duration: 0.4)) {
                        self.deleteStatus = nil
                        self.performDismiss()
                    }
                }
            }
        }
    }

    private func extractSHA256FromURL() -> String {
        // Try to extract the 64-char hash from the URL path
        let lastComponent = url.deletingPathExtension().lastPathComponent
        if lastComponent.count == 64 && lastComponent.allSatisfy({ $0.isHexDigit }) {
            return lastComponent
        }
        return ""
    }

    private func downloadMedia() async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let mediaType = isVideo ? "video" : isGIF ? "GIF" : "image"
            throw NSError(domain: "DownloadError", code: status, userInfo: [NSLocalizedDescriptionKey: "Failed to download \(mediaType): HTTP \(status)"])
        }

        return data
    }

    private func determineContentType() -> String {
        if isVideo {
            let ext = url.pathExtension.lowercased()
            switch ext {
            case "mp4": return "video/mp4"
            case "mov": return "video/quicktime"
            case "webm": return "video/webm"
            case "m4v": return "video/mp4"
            case "hevc", "h265": return "video/hevc"
            default: return "video/mp4"
            }
        } else if isGIF {
            return "image/gif"
        } else {
            let ext = url.pathExtension.lowercased()
            switch ext {
            case "jpg", "jpeg": return "image/jpeg"
            case "png": return "image/png"
            case "webp": return "image/webp"
            case "avif": return "image/avif"
            case "heic": return "image/heic"
            default: return "image/jpeg"
            }
        }
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
                        .font(.system(size: 14, weight: .semibold))
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(Capsule().fill(Color.blue.opacity(0.85)))
                .foregroundColor(.white)

            case .success:
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Mirrored to Blossom")
                        .font(.system(size: 14, weight: .semibold))
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(Capsule().fill(Color(red: 0.2, green: 0.8, blue: 0.6)))
                .foregroundColor(.white)

            case .failed(let message):
                HStack(spacing: 8) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Text(message)
                        .font(.system(size: 13, weight: .semibold))
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
                        .font(.system(size: 14, weight: .semibold))
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(Capsule().fill(Color.red.opacity(0.85)))
                .foregroundColor(.white)

            case .success:
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Deleted")
                        .font(.system(size: 14, weight: .semibold))
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(Capsule().fill(Color(red: 0.8, green: 0.2, blue: 0.2)))
                .foregroundColor(.white)

            case .failed(let message):
                HStack(spacing: 8) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Text(message)
                        .font(.system(size: 13, weight: .semibold))
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
                        .font(.system(size: 40))
                        .foregroundColor(.orange)
                    Text("Failed to load image")
                        .foregroundColor(.white)
                        .font(.headline)
                    Text(url.absoluteString)
                        .foregroundColor(.secondary)
                        .font(.caption)
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
            if let data = await MediaCacheService.shared.fetchData(url: url),
               let img = PlatformImage(data: data) {
                await MainActor.run { self.image = img }
            } else {
                await MainActor.run { self.loadFailed = true }
            }
        }
    }
}
