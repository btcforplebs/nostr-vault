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
    @State private var pendingDelete: MediaDeleteScope?
    @State private var showingBlockConfirm = false
    @State private var isMirroringToLocal = false
    @State private var isPushingToMirrors = false
    @State private var onPhone = false
    @ObservedObject private var backupStore = BlossomBackupStore.shared

    var body: some View {
        // Not a Button around the whole row: the row holds its own Upload,
        // Save to Vault and Copy link buttons, and on iOS a Button nested in
        // a Button never gets the tap, so all three opened the viewer
        // instead. The open action covers everything but those three.
        HStack(spacing: 12) {
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

                // Location Status: on this phone or not, plus how many of
                // your Blossom servers hold it.
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        if onPhone {
                            Image(systemName: "internaldrive.fill")
                                .font(.appSystem(size: 13))
                                .foregroundColor(.green)
                                .accessibilityLabel("On phone")
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: "link")
                                    .font(.appSystem(size: 11))
                                Text(item.url.host ?? "Link only")
                                    .font(.appSystem(size: 13, weight: .medium))
                                    .lineLimit(1)
                            }
                            .foregroundColor(.blue)
                        }
                        if let hash {
                            BlossomBackupBadge(hash: hash)
                        }
                    }
                }

                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)

            // Action Buttons
            HStack(spacing: 8) {
                // Upload only when it is on the phone and some server lacks it
                if needsMirror {
                    Button(action: pushToMirrors) {
                        Image(systemName: isPushingToMirrors ? "arrow.up.circle.fill" : "arrow.up.circle")
                            .font(.appSystem(size: 22))
                            .foregroundColor(isPushingToMirrors ? .secondary : .havenPurple)
                    }
                    .buttonStyle(.plain)
                    .disabled(isPushingToMirrors)
                }

                // Save to Vault (only when it is not on the phone yet)
                if !onPhone {
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
        .task(id: item.id) {
            refreshOnPhone()
        }
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
                    showingBlockConfirm = true
                }) {
                    Label("Block User", systemImage: "hand.raised.fill")
                }
            }
        }
        .confirmMediaDelete($pendingDelete, hash: hash) { scope in
            switch scope {
            case .mirrors: onDeleteFromMirrors?(item)
            case .everywhere: onDeleteEverywhere?(item)
            }
        }
        .confirmBlockUser(isPresented: $showingBlockConfirm) {
            guard let pubkey = item.pubkey,
                  let data = Bech32.hexToData(pubkey),
                  let npub = Bech32.encode(hrp: "npub", data: data) else { return }
            configService.blockProfile(npub)
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
