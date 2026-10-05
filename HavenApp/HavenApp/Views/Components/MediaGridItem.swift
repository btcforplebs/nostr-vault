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
    @State private var pendingDelete: MediaDeleteScope?
    @State private var isMirroringToLocal = false
    @State private var isPushingToMirrors = false
    @State private var onPhone = false
    @ObservedObject private var backupStore = BlossomBackupStore.shared

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
            .overlay(alignment: .bottomTrailing) {
                // How many of your Blossom servers hold it, so you can spot
                // what is not backed up without opening it.
                if let hash, !configService.config.activeBlossomMirrors.isEmpty {
                    BlossomBackupBadge(hash: hash, compact: true)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .scaleEffect(isHovered ? 1.04 : 1.0)
            .zIndex(isHovered ? 1.0 : 0.0)
            .animation(Motion.control, value: isHovered)
            .onHover { hovering in isHovered = hovering }
            .onTapGesture { onSelect() }
            .task(id: item.id) { refreshOnPhone() }
            .onReceive(NotificationCenter.default.publisher(for: .havenMediaCacheCleared)) { _ in
                refreshOnPhone()
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

            if !onPhone {
                Button(action: {
                    mirrorToLocalRelay()
                }) {
                    Label(isMirroringToLocal ? "Saving..." : "Save to Vault", systemImage: "internaldrive")
                }
                .disabled(isMirroringToLocal)
            }

            // On the phone, and some Blossom server does not have it yet
            if needsMirror {
                Button(action: {
                    pushToMirrors()
                }) {
                    Label(isPushingToMirrors ? "Mirroring..." : "Mirror to Blossom", systemImage: "arrow.up.circle")
                }
                .disabled(isPushingToMirrors)
            }

            if onDeleteFromMirrors != nil || onDeleteEverywhere != nil {
                Menu {
                    if onDeleteFromMirrors != nil {
                        Button(role: .destructive, action: {
                            pendingDelete = .mirrors
                        }) {
                            Label("Delete from mirrors", systemImage: "trash")
                        }
                    }
                    if onDeleteEverywhere != nil {
                        Button(role: .destructive, action: {
                            pendingDelete = .everywhere
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
        .confirmMediaDelete($pendingDelete) { scope in
            switch scope {
            case .mirrors: onDeleteFromMirrors?(item)
            case .everywhere: onDeleteEverywhere?(item)
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

    private var hash: String? { MediaCacheService.blossomHash(in: item.url) }

    /// On the phone and at least one Blossom server is not known to have it.
    private var needsMirror: Bool {
        guard onPhone, let hash else { return false }
        return backupStore.summary(hash: hash, mirrors: configService.config.activeBlossomMirrors)?.needsMirror == true
    }

    private func refreshOnPhone() {
        onPhone = MediaCacheService.shared.getSource(for: item.url) == .blossom
    }

    private func mirrorToLocalRelay() {
        isMirroringToLocal = true
        Task { @MainActor in
            let outcome = await MediaBackupActions.saveToVault(url: item.url, configService: configService, nostrService: nostrService)
            isMirroringToLocal = false
            refreshOnPhone()
            MediaBackupActions.announce(outcome)
            if outcome != .failed { onMirrorComplete?() }
        }
    }

    private func pushToMirrors() {
        guard let hash else {
            ErrorNotificationManager.shared.show(
                String(localized: "media.push.error.noHash"),
                icon: "exclamationmark.icloud.fill",
                style: .warning
            )
            return
        }
        isPushingToMirrors = true
        Task { @MainActor in
            let ok = await MediaBackupActions.mirrorMissing(hash: hash, configService: configService, nostrService: nostrService)
            isPushingToMirrors = false
            MediaBackupActions.announceMirror(ok)
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
