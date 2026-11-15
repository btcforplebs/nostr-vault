import SwiftUI
import AVKit
import CryptoKit
import os.log

extension FeedMediaViewer {
    // MARK: - Top-row actions

    private static let doneGreen = Color(red: 0.2, green: 0.8, blue: 0.6).opacity(0.8)

    /// Copy (the media itself), Save, Share, then ··· for the link, Mirror
    /// and Delete. Labels drop out when [showLabels] is false, leaving the
    /// icon in each capsule. A locked DM file gets no ···: it stays on the
    /// phone, so there is no link to copy and nothing on a server to delete.
    @ViewBuilder
    func topActions(showLabels: Bool) -> some View {
        HStack(spacing: 6) {
            if !isLoadingType {
                Button {
                    copyMediaTapped()
                } label: {
                    actionCapsule(
                        icon: mediaCopy == .copied ? "checkmark.circle.fill" : "doc.on.doc",
                        label: mediaCopy == .copied ? "Copied" : "Copy",
                        showLabel: showLabels,
                        fill: mediaCopy == .copied ? Self.doneGreen : Color.black.opacity(0.6),
                        busy: mediaCopy == .copying
                    )
                }
                .buttonStyle(.plain)
                .disabled(mediaCopy == .copying)
                .accessibilityLabel(mediaCopy == .copied ? "Copied" : (isVideo ? "Copy video" : "Copy photo"))

                #if os(iOS)
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

                Button {
                    shareTapped()
                } label: {
                    actionCapsule(icon: "square.and.arrow.up", label: "Share", showLabel: showLabels,
                                  fill: Color.black.opacity(0.6), busy: isPreparingShare)
                }
                .buttonStyle(.plain)
                .disabled(isPreparingShare)
                .accessibilityLabel("Share")
                #endif

                if !DMFileTransfer.isOpenedFile(url) {
                    moreMenu(showLabel: showLabels)
                }
            }
        }
        .shadow(color: Color.black.opacity(0.3), radius: 4)
    }

    /// Copy link, Mirror, Delete: the things you do less often, out of the
    /// way of the photo but no longer hidden behind a long-press.
    private func moreMenu(showLabel: Bool) -> some View {
        Menu {
            if let link = shareableLink() {
                Button {
                    PlatformClipboard.copy(link)
                    ActionToastManager.shared.show(icon: "link", message: "Link copied", tone: .success)
                } label: {
                    Label("Copy link", systemImage: "link")
                }
            }
            if canMirror {
                if isOnMirror {
                    Button {} label: {
                        Label("On your media servers", systemImage: "checkmark.circle")
                    }
                    .disabled(true)
                } else {
                    Button {
                        mirrorToBlossomTapped()
                    } label: {
                        Label("Copy to your media servers", systemImage: "arrow.down.circle")
                    }
                    .disabled(isMirroring)
                }
            }
            Divider()
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
        } label: {
            // Icon only: "···" says it, and a label would push Copy and
            // Save into icons sooner on narrow phones.
            actionCapsule(icon: "ellipsis", label: "", showLabel: false, fill: Color.black.opacity(0.6))
                .contentShape(Capsule())
        }
        #if os(macOS)
        .menuStyle(.button)
        .menuIndicator(.hidden)
        #endif
        .buttonStyle(.plain)
        .accessibilityLabel("More")
    }

    /// Mirror needs a vault URL the media servers can be told about.
    private var canMirror: Bool {
        guard let localURL = viewerLocalURL() else { return false }
        return configService.hasExternalShareURL(for: localURL)
    }

    /// The link Copy link gives: your own mirror once it is there, else the
    /// public address the post used. Nothing for a file only this device has.
    private func shareableLink() -> String? {
        if isOnMirror && canMirror { return getMirroredLink() }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(),
              !["127.0.0.1", "localhost", "0.0.0.0"].contains(host),
              !host.hasSuffix(".fips") else { return nil }
        return url.absoluteString
    }

    private func copyMediaTapped() {
        mediaCopy = .copying
        let mediaURL = url
        let clip = isVideo
        Task {
            do {
                let prepared = try await ViewerMediaTransfer.prepare(mediaURL, isClip: clip)
                try ViewerMediaTransfer.copy(prepared, isClip: clip)
                withAnimation(Motion.pop) { mediaCopy = .copied }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation(Motion.fade) { mediaCopy = .idle }
                }
            } catch {
                mediaCopy = .idle
                ErrorNotificationManager.shared.show(error.localizedDescription, icon: "exclamationmark.triangle.fill")
            }
        }
    }

    #if os(iOS)
    private func shareTapped() {
        isPreparingShare = true
        let mediaURL = url
        let clip = isVideo
        Task {
            defer { isPreparingShare = false }
            do {
                let prepared = try await ViewerMediaTransfer.prepare(mediaURL, isClip: clip)
                shareFile = ViewerShareFile(url: prepared.file)
            } catch {
                ErrorNotificationManager.shared.show(error.localizedDescription, icon: "exclamationmark.triangle.fill")
            }
        }
    }
    #endif

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
        guard !DMFileTransfer.isOpenedFile(url) else { return }
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
                            mirrorStatus = .failed("Couldn't save to your vault")
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

    func deleteFromMirrorsTapped() {
        deleteStatus = .loading

        Task {
            let sha256 = extractSHA256FromURL()
            guard !sha256.isEmpty else {
                await MainActor.run {
                    withAnimation(Motion.panel) {
                        deleteStatus = .failed("Could not extract hash from URL")
                    }
                }
                return
            }

            let report = await blossomService.deleteFromMirrorsReport(sha256: sha256, photoURL: url, includeHomeVault: false)
            // The cloud badges cache each server's answer for the session;
            // ask again so they stop showing the pre-delete count.
            await BlossomBackupStore.shared.refresh(hash: sha256, service: blossomService, force: true)
            await MainActor.run {
                withAnimation(Motion.panel) {
                    let message = report.mirrorsMessage
                    if !message.ok {
                        deleteStatus = .failed(message.text)
                    } else if report.skipped.isEmpty {
                        deleteStatus = .success
                    } else {
                        // Names the vault it left alone ("Deleted from mirrors. Skipped: …").
                        deleteStatus = .successNote(message.text)
                    }
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

    func deleteEverywhereTapped() {
        deleteStatus = .loading

        Task {
            let sha256 = extractSHA256FromURL()
            guard !sha256.isEmpty else {
                await MainActor.run {
                    withAnimation(Motion.panel) {
                        deleteStatus = .failed("Could not extract hash from URL")
                    }
                }
                return
            }

            let localSuccess = await blossomService.deleteFromLocal(sha256: sha256)
            let report = await blossomService.deleteFromMirrorsReport(sha256: sha256, photoURL: url, includeHomeVault: true)
            let leftover = BlossomService.deleteEverywhereLeftover(localDeleted: localSuccess, mirrors: report)
            // The cloud badges cache each server's answer for the session;
            // ask again so they stop showing the pre-delete count.
            await BlossomBackupStore.shared.refresh(hash: sha256, service: blossomService, force: true)

            await MainActor.run {
                withAnimation(Motion.panel) {
                    deleteStatus = leftover.map { .failed($0) } ?? .success
                    if localSuccess { isOnMirror = false }
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

    func extractSHA256FromURL() -> String {
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
    func updateMirrorStatus() {
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
    func mirrorStatusView(_ status: MirrorStatus) -> some View {
        VStack {
            switch status {
            case .loading:
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(.white)
                    Text("Copying to your media servers...")
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
                    Text("Copied to your media servers")
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
    func deleteStatusView(_ status: DeleteStatus) -> some View {
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

            case .success, .successNote:
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.appSystem(size: 14, weight: .semibold))
                    Text(status.successText)
                        .font(.appSystem(size: 14, weight: .semibold))
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
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
