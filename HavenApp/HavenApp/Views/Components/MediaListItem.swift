import SwiftUI
#if os(iOS)
import Photos
#endif

struct MediaListItem: View {
    let item: MediaItem
    var onDeleteFromMirrors: ((MediaItem) -> Void)? = nil
    var onDeleteEverywhere: ((MediaItem) -> Void)? = nil
    var onMirrorComplete: (() -> Void)? = nil
    let onSelect: () -> Void
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    @State private var showingReportDialog = false
    @State private var isMirroringToLocal = false
    @State private var isPushingToMirrors = false
    @State private var mirroredCount: Int? = nil
    @State private var totalMirrors: Int = 0

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                // Thumbnail
                Color.clear
                    .aspectRatio(1.0, contentMode: .fit)
                    .frame(width: 60, height: 60)
                    .overlay(
                        Group {
                            if item.type == .video {
                                VideoThumbnailView(url: item.url, mimeType: item.mimeType)
                            } else if item.type == .audio {
                                ZStack {
                                    Color(red: 0.1, green: 0.1, blue: 0.14)
                                    Image(systemName: "waveform")
                                        .font(.appSystem(size: 20))
                                        .foregroundColor(.havenPurple)
                                }
                            } else if item.type == .unknown {
                                ZStack {
                                    Color(red: 0.1, green: 0.1, blue: 0.14)
                                    Image(systemName: "doc.fill")
                                        .font(.appSystem(size: 18))
                                        .foregroundColor(.havenPurple.opacity(0.6))
                                }
                            } else if item.isAnimatedGIF {
                                AnimatedImage(url: item.url, contentMode: .fill, shouldAnimate: false, targetSize: CGSize(width: 60, height: 60))
                            } else {
                                RetryableAsyncImage(url: item.url, contentMode: .fill, targetSize: CGSize(width: 60, height: 60))
                            }
                        }
                    )
                    .background(Color.black.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                // Type Icon
                Image(systemName: item.type == .video ? "video.fill" : item.type == .audio ? "waveform" : item.type == .image ? "photo.fill" : "doc.fill")
                    .font(.appSystem(size: 20))
                    .foregroundColor(.havenPurple)
                    .frame(width: 32)

                // Location Status
                VStack(alignment: .leading, spacing: 4) {
                    if !isRemoteMedia {
                        HStack(spacing: 8) {
                            // Local storage — icon only
                            Image(systemName: "internaldrive.fill")
                                .font(.appSystem(size: 13))
                                .foregroundColor(.green)

                            // Blossom mirror count (x/x)
                            if totalMirrors > 0 {
                                HStack(spacing: 4) {
                                    Image(systemName: "cloud.fill")
                                        .font(.appSystem(size: 11))
                                    Text(mirrorCountText)
                                        .font(.appSystem(size: 13, weight: .medium))
                                }
                                .foregroundColor(mirrorTint)
                            }
                        }
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "cloud.fill")
                                .font(.appSystem(size: 11))
                            Text(item.url.host ?? "Remote")
                                .font(.appSystem(size: 13, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundColor(.blue)
                    }
                }

                Spacer()

                // Action Buttons
                HStack(spacing: 8) {
                    // Upload to mirrors (only for local items with mirrors configured)
                    if !isRemoteMedia && !configService.config.activeBlossomMirrors.isEmpty {
                        Button(action: pushToMirrors) {
                            Image(systemName: isPushingToMirrors ? "arrow.up.circle.fill" : "arrow.up.circle")
                                .font(.appSystem(size: 22))
                                .foregroundColor(isPushingToMirrors ? .secondary : .havenPurple)
                        }
                        .buttonStyle(.plain)
                        .disabled(isPushingToMirrors)
                    }

                    // Download to local (only for remote items not on local)
                    if !isOnMirror && configService.hasExternalShareURL(for: URL(string: "https://localhost")!) {
                        Button(action: mirrorToLocalRelay) {
                            Image(systemName: isMirroringToLocal ? "arrow.down.circle.fill" : "arrow.down.circle")
                                .font(.appSystem(size: 22))
                                .foregroundColor(isMirroringToLocal ? .secondary : .havenPurple)
                        }
                        .buttonStyle(.plain)
                        .disabled(isMirroringToLocal)
                    }

                    // Copy link
                    Button(action: {
                        PlatformClipboard.copy(item.shareURL(with: configService).absoluteString)
                    }) {
                        Image(systemName: "doc.on.doc")
                            .font(.appSystem(size: 22))
                            .foregroundColor(.havenPurple)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.trailing, 8)
            }
            .padding(12)
            .background(Color(red: 0.1, green: 0.1, blue: 0.14).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .task(id: item.id) {
            await loadMirrorCount()
        }
        .contextMenu {
            Button(action: {
                PlatformClipboard.copy(item.shareURL(with: configService).absoluteString)
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
            #endif

            if !isOnMirror && configService.hasExternalShareURL(for: URL(string: "https://localhost")!) {
                Button(action: {
                    mirrorToLocalRelay()
                }) {
                    Label(isMirroringToLocal ? "Mirroring..." : "Mirror to Blossom", systemImage: "arrow.down.circle")
                }
                .disabled(isMirroringToLocal)
            }

            if !isRemoteMedia && !configService.config.activeBlossomMirrors.isEmpty {
                Button(action: {
                    pushToMirrors()
                }) {
                    Label(isPushingToMirrors ? "Pushing..." : "Push to Mirrors", systemImage: "arrow.up.circle")
                }
                .disabled(isPushingToMirrors)
            }

            if onDeleteFromMirrors != nil || onDeleteEverywhere != nil {
                Menu {
                    if let onDeleteFromMirrors = onDeleteFromMirrors {
                        Button(role: .destructive, action: {
                            onDeleteFromMirrors(item)
                        }) {
                            Label("Delete from mirrors", systemImage: "trash")
                        }
                    }
                    if let onDeleteEverywhere = onDeleteEverywhere {
                        Button(role: .destructive, action: {
                            onDeleteEverywhere(item)
                        }) {
                            Label("Delete everywhere", systemImage: "trash.fill")
                        }
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }

            Divider()

            if MediaCacheService.shared.isKnown404(url: item.url) {
                Button(action: {
                    MediaCacheService.shared.unmarkNotFound(url: item.url)
                }) {
                    Label("Remove from 404", systemImage: "arrow.uturn.backward.circle")
                }
            } else {
                Button(action: {
                    MediaCacheService.shared.markNotFound(url: item.url)
                }) {
                    Label("Mark as 404", systemImage: "xmark.octagon")
                }
            }
            if let pubkey = item.pubkey, pubkey != nostrService.activeHexPubkey {
                Button(action: {
                    showingReportDialog = true
                }) {
                    Label("Report Media", systemImage: "flag.fill")
                }

                Divider()

                Button(action: {
                    guard let data = Bech32.hexToData(pubkey),
                          let npub = Bech32.encode(hrp: "npub", data: data) else { return }
                    configService.blockProfile(npub)
                }) {
                    Label("Block User", systemImage: "hand.raised.fill")
                }
            }
        }
        .sheet(isPresented: $showingReportDialog) {
            UGCReportingDialog(eventId: nil, pubkey: item.pubkey ?? "", onDismiss: { showingReportDialog = false }) {
                nostrService.objectWillChange.send()
            }
            .environmentObject(nostrService)
            .environmentObject(configService)
        }
    }

    private var isRemoteMedia: Bool {
        let host = item.url.host?.lowercased() ?? ""
        return host != "localhost" && host != "127.0.0.1" && host != "0.0.0.0"
    }

    private var isOnMirror: Bool {
        let currentMirrorHosts: Set<String> = Set(
            configService.config.activeBlossomMirrors.compactMap {
                URL(string: $0)?.host?.lowercased()
            }
        )
        guard let host = item.url.host?.lowercased() else { return false }
        return currentMirrorHosts.contains(host) || host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0"
    }

    private func mirrorToLocalRelay() {
        isMirroringToLocal = true
        Task {
            let service = BlossomService(configService: configService, nostrService: nostrService)
            let success = await service.downloadFromURL(url: item.url)
            await MainActor.run {
                isMirroringToLocal = false
                if success {
                    ActionToastManager.shared.show(
                        icon: "internaldrive.fill",
                        message: String(localized: "media.mirror.saved"),
                        color: Color.havenVerified
                    )
                } else {
                    ErrorNotificationManager.shared.show(
                        String(localized: "media.mirror.failed"),
                        icon: "exclamationmark.icloud.fill"
                    )
                }
                if success {
                    onMirrorComplete?()
                }
            }
        }
    }

    private func pushToMirrors() {
        isPushingToMirrors = true
        Task {
            let service = BlossomService(configService: configService, nostrService: nostrService)
            let sha256 = item.url.deletingPathExtension().lastPathComponent
            guard sha256.count == 64 && sha256.allSatisfy({ $0.isHexDigit }) else {
                await MainActor.run {
                    isPushingToMirrors = false
                    ErrorNotificationManager.shared.show(
                        String(localized: "media.push.error.noHash"),
                        icon: "exclamationmark.icloud.fill",
                        style: .warning
                    )
                }
                return
            }
            let success = await service.pushLocalToMirrors(sha256: sha256)
            await MainActor.run {
                isPushingToMirrors = false
                if success {
                    ActionToastManager.shared.show(
                        icon: "icloud.and.arrow.up.fill",
                        message: String(localized: "media.push.succeeded"),
                        color: Color.havenVerified
                    )
                } else {
                    ErrorNotificationManager.shared.show(
                        String(localized: "media.push.failed"),
                        icon: "exclamationmark.icloud.fill"
                    )
                }
            }
        }
    }

    #if os(iOS)
    private func saveMediaToPhotos(item: MediaItem) {
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

    private func saveMediaToPhotos() {
        saveMediaToPhotos(item: item)
    }
    #endif

    /// Cloud label text, e.g. "2/3". Shows the total while the count is loading.
    private var mirrorCountText: String {
        if let count = mirroredCount {
            return "\(count)/\(totalMirrors)"
        }
        return "–/\(totalMirrors)"
    }

    /// Tint for the cloud badge: gray while loading / not mirrored, orange when
    /// partially mirrored, green when present on every configured mirror.
    private var mirrorTint: Color {
        guard let count = mirroredCount, count > 0 else { return .secondary }
        return count >= totalMirrors ? .green : .orange
    }

    /// Checks how many configured Blossom mirrors hold this blob.
    private func loadMirrorCount() async {
        guard !isRemoteMedia else { return }
        let mirrors = configService.config.activeBlossomMirrors
        await MainActor.run { totalMirrors = mirrors.count }
        guard !mirrors.isEmpty else { return }

        let sha256 = item.url.deletingPathExtension().lastPathComponent
        guard sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit }) else { return }

        let service = BlossomService(configService: configService, nostrService: nostrService)
        let status = await service.checkMirrorStatus(sha256: sha256)
        let count = status.values.filter { $0 }.count
        await MainActor.run { mirroredCount = count }
    }
}
