import SwiftUI
#if os(iOS)
import Photos
#endif

struct MediaGridItem: View {
    let item: MediaItem
    var onDeleteFromMirrors: ((MediaItem) -> Void)? = nil
    var onDeleteEverywhere: ((MediaItem) -> Void)? = nil
    var onMirrorComplete: (() -> Void)? = nil
    let onSelect: () -> Void
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    @State private var isHovered = false
    @State private var showingReportDialog = false
    @State private var isMirroringToLocal = false
    @State private var isPushingToMirrors = false

    var body: some View {
        Color.clear
            .aspectRatio(1.0, contentMode: .fit)
            .overlay(
                Group {
                    // Use item.type instead of url extension checks for Blossom compatibility
                    if item.type == .video {
                        VideoThumbnailView(url: item.url, mimeType: item.mimeType)
                    } else if item.type == .audio {
                        ZStack {
                            Color(red: 0.1, green: 0.1, blue: 0.14)
                            Image(systemName: "waveform")
                                .font(.appSystem(size: 36))
                                .foregroundColor(.havenPurple)
                        }
                    } else if item.type == .unknown {
                        ZStack {
                            Color(red: 0.1, green: 0.1, blue: 0.14)
                            VStack(spacing: 4) {
                                Image(systemName: "doc.fill")
                                    .font(.appSystem(size: 28))
                                    .foregroundColor(.havenPurple.opacity(0.6))
                                if let mime = item.mimeType {
                                    Text(mime)
                                        .font(.appSystem(size: 9, weight: .medium, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(4)
                        }
                    } else if item.isAnimatedGIF {
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
            .animation(Motion.control, value: isHovered)
            .onHover { hovering in isHovered = hovering }
            .onTapGesture { onSelect() }
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

            // Push local-only items to external mirrors
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
}
