import Foundation
import AVFoundation
import CoreMedia
import SwiftUI

// MARK: - MediaKind / MediaKindResolver

/// Unified media classification shared by every surface (feed cards, the
/// full-screen viewer, the media gallery). Replaces the three per-view
/// implementations that each mixed extension checks and MIME prefixes slightly
/// differently.
enum MediaKind {
    case video, gif, image, audio, unknown
}

enum MediaKindResolver {
    static func kind(fromMime mime: String) -> MediaKind {
        let lower = mime.lowercased()
        if lower.contains("image/gif") { return .gif }
        if lower.hasPrefix("image/") { return .image }
        if lower.hasPrefix("video/") { return .video }
        if lower.hasPrefix("audio/") { return .audio }
        return .unknown
    }

    /// Resolves without touching the network: extension, caller-provided MIME
    /// hint, the note's `imeta` MIME, then the detector's cache. Generic MIME types
    /// (application/octet-stream) are ignored — they carry no information.
    static func cachedKind(for url: URL, mimeHint: String? = nil) -> MediaKind? {
        let ext = url.pathExtension.lowercased()
        if ext == "gif" { return .gif }
        if SupportedMediaFormats.videoExtensions.contains(ext) { return .video }
        if SupportedMediaFormats.imageExtensions.contains(ext) { return .image }
        if SupportedMediaFormats.audioExtensions.contains(ext) { return .audio }
        if let hint = mimeHint, !MediaTypeDetector.isGenericContentType(hint) {
            return kind(fromMime: hint)
        }
        if let hint = MediaHints.shared.hint(for: url)?.mime,
           !MediaTypeDetector.isGenericContentType(hint) {
            return kind(fromMime: hint)
        }
        if let cached = MediaTypeDetector.shared.getCachedContentType(for: url),
           !MediaTypeDetector.isGenericContentType(cached) {
            return kind(fromMime: cached)
        }
        return nil
    }

    /// Full resolution: cached paths first, then a HEAD request with
    /// magic-byte sniffing for servers that answer application/octet-stream.
    static func kind(for url: URL, mimeHint: String? = nil) async -> MediaKind {
        if let cached = cachedKind(for: url, mimeHint: mimeHint) { return cached }
        if let detected = await MediaTypeDetector.shared.detectContentTypeAsync(for: url),
           !MediaTypeDetector.isGenericContentType(detected) {
            return kind(fromMime: detected)
        }
        return .unknown
    }
}

// MARK: - VideoPlaybackService

/// Single source of truth for turning a media URL into a playing AVPlayer.
///
/// Every playback surface gets its player here. The service owns:
///  - candidate resolution: verified local file → remote with known/sniffed
///    MIME → remote with container-guess fallbacks
///  - the automatic failure ladder: a failed AVPlayerItem advances to the next
///    candidate on the SAME player (views never participate in recovery)
///  - mute/audio-session policy per playback intent
///  - looping
///  - diagnostic logging to the in-app relay log, so playback failures are
///    debuggable on device without a console
/// Tracks URLs whose candidate ladder ran dry, so playback surfaces can show a
/// real error instead of a black rectangle. Observed by the video views; the
/// service is the only writer.
@MainActor
final class VideoPlaybackFailures: ObservableObject {
    static let shared = VideoPlaybackFailures()
    @Published private(set) var exhausted: Set<URL> = []

    private init() {}

    func mark(_ url: URL) { exhausted.insert(url) }
    func clear(_ url: URL) { exhausted.remove(url) }
    func hasFailed(_ url: URL) -> Bool { exhausted.contains(url) }
}

final class VideoPlaybackService: @unchecked Sendable {
    static let shared = VideoPlaybackService()

    /// What the caller is going to do with the player. Determines mute and
    /// audio-session policy — the one place that decides either.
    enum Intent {
        /// Muted autoplay in a feed card; mixes with background audio.
        case inline
        /// Unmuted full-screen playback; takes over the audio session.
        case fullScreen
        /// Media-gallery playback via AVPlayerViewController; unmuted.
        case standalone
    }

    struct Candidate: Sendable {
        let assetURL: URL
        let mimeOverride: String?
        let label: String

        var assetOptions: [String: Any] {
            guard let mimeOverride else { return [:] }
            return [AVURLAssetOverrideMIMETypeKey: mimeOverride]
        }
    }

    private final class Ladder {
        let sourceURL: URL
        var candidates: [Candidate]
        var index = 0
        var statusObservation: NSKeyValueObservation?
        var endObserver: NSObjectProtocol?

        init(sourceURL: URL, candidates: [Candidate]) {
            self.sourceURL = sourceURL
            self.candidates = candidates
        }

        func tearDown() {
            statusObservation?.invalidate()
            statusObservation = nil
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
                self.endObserver = nil
            }
        }
    }

    private var ladders: [URL: Ladder] = [:]
    /// Source URLs whose local-file copy failed to play — resolution skips the
    /// local candidate for these so a bad copy can't shadow the remote again.
    private var skipLocal: Set<URL> = []
    private let lock = NSLock()

    private init() {}

    // MARK: Player factory

    /// Async entry point: warms MIME detection (HEAD + magic-byte sniff) for
    /// extensionless remote URLs before building the player. Prefer this from
    /// views — it is the whole "detect then set up" dance in one call.
    func preparedPlayer(for url: URL, mimeHint: String? = nil, intent: Intent) async -> AVPlayer {
        if url.pathExtension.isEmpty && !url.isFileURL {
            _ = await MediaTypeDetector.shared.detectContentTypeAsync(for: url)
        }
        // Candidate resolution sha256-verifies the cached blob (up to 64 MB of
        // file I/O), so it must not run on the main thread. Resolve off-main and
        // hand the finished list to the main-actor factory.
        let resolved = await Task.detached(priority: .userInitiated) { [self] in
            resolveCandidates(for: url, mimeHint: mimeHint)
        }.value
        return await MainActor.run {
            player(for: url, mimeHint: mimeHint, intent: intent, candidates: resolved)
        }
    }

    /// Synchronous factory. Uses whatever MIME information is already cached;
    /// callers with extensionless URLs should prefer `preparedPlayer`.
    ///
    /// - Parameter candidates: pre-resolved ladder. Pass this whenever the
    ///   caller could resolve off-main — resolving here blocks the main thread
    ///   on integrity hashing.
    @MainActor
    func player(for url: URL, mimeHint: String? = nil, intent: Intent, candidates: [Candidate]? = nil) -> AVPlayer {
        applyAudioSession(for: intent)

        if let existing = VideoPlayerCache.shared.storedPlayer(for: url) {
            let exhausted = existing.currentItem?.status == .failed || existing.currentItem?.error != nil
            if !exhausted {
                applyMutePolicy(to: existing, intent: intent)
                return existing
            }
            // Ladder ran dry earlier — rebuild from scratch; the network (or a
            // healed local copy) may work now.
            VideoPlayerCache.shared.removePlayer(for: url)
            invalidateLadder(for: url)
        }

        let resolved = candidates ?? resolveCandidates(for: url, mimeHint: mimeHint)
        let ladder = Ladder(sourceURL: url, candidates: resolved)
        let player = AVPlayer(playerItem: makeItem(for: resolved[0]))
        applyMutePolicy(to: player, intent: intent)
        attach(ladder, to: player)

        lock.lock()
        ladders[url] = ladder
        lock.unlock()

        // Fresh ladder — this URL gets another chance to play.
        VideoPlaybackFailures.shared.clear(url)
        VideoPlayerCache.shared.store(player, for: url)
        log(url, "playing via \(resolved[0].label)")
        return player
    }

    /// One place that flips mute AND keeps the audio session consistent with it.
    @MainActor
    func setMuted(_ muted: Bool, on player: AVPlayer) {
        player.isMuted = muted
        if muted {
            AudioSessionManager.shared.enableMixingWithOthers()
        } else {
            AudioSessionManager.shared.enablePlayback()
        }
    }

    // MARK: Candidate resolution

    /// The ladder every playback and thumbnail attempt walks, in order:
    /// 1. verified local file (sha256-checked, symlinked with a usable extension)
    /// 2. remote URL with the known/sniffed MIME override (extensionless only)
    /// 3. remote URL guessed as video/mp4, then video/quicktime (extensionless only)
    func resolveCandidates(for url: URL, mimeHint: String? = nil) -> [Candidate] {
        var out: [Candidate] = []

        lock.lock()
        let localAllowed = !skipLocal.contains(url)
        lock.unlock()

        if localAllowed, !url.isFileURL,
           let local = MediaCacheService.shared.preparePlayableURL(for: url, extensionHint: mimeHint) {
            out.append(Candidate(assetURL: local, mimeOverride: nil, label: "local file"))
        }

        if url.isFileURL {
            out.append(Candidate(assetURL: url, mimeOverride: nil, label: "file"))
        } else if url.pathExtension.isEmpty {
            let known = [mimeHint, MediaTypeDetector.shared.getCachedContentType(for: url)]
                .compactMap { $0 }
                .first { !MediaTypeDetector.isGenericContentType($0) }
            if let known {
                out.append(Candidate(assetURL: url, mimeOverride: known, label: "remote as \(known)"))
            }
            for guess in ["video/mp4", "video/quicktime"] where known?.lowercased() != guess {
                out.append(Candidate(assetURL: url, mimeOverride: guess, label: "remote as \(guess) (guess)"))
            }
        } else {
            out.append(Candidate(assetURL: url, mimeOverride: nil, label: "remote"))
        }

        return out
    }

    private func makeItem(for candidate: Candidate) -> AVPlayerItem {
        let asset = AVURLAsset(url: candidate.assetURL, options: candidate.assetOptions)
        return AVPlayerItem(asset: asset)
    }

    // MARK: Failure ladder

    private func attach(_ ladder: Ladder, to player: AVPlayer) {
        ladder.tearDown()
        guard let item = player.currentItem else { return }

        let sourceURL = ladder.sourceURL
        ladder.statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak player] item, _ in
            guard item.status == .failed else { return }
            DispatchQueue.main.async {
                guard let self, let player else { return }
                self.advanceLadder(for: sourceURL, player: player, error: item.error)
            }
        }

        ladder.endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }
    }

    @MainActor
    private func advanceLadder(for url: URL, player: AVPlayer, error: Error?) {
        lock.lock()
        let ladder = ladders[url]
        lock.unlock()
        guard let ladder, ladder.index < ladder.candidates.count else { return }

        let failed = ladder.candidates[ladder.index]
        let nsError = error as NSError?
        let errorText = nsError.map { "\($0.domain) \($0.code)" } ?? "unknown error"

        // A local copy that fails to decode is bad — stop preferring it and drop
        // the disposable cached copy so it can heal from the network.
        if failed.assetURL.isFileURL, !url.isFileURL {
            lock.lock()
            skipLocal.insert(url)
            lock.unlock()
            MediaCacheService.shared.discardCachedCopy(for: url)
        }

        ladder.index += 1
        guard ladder.index < ladder.candidates.count else {
            log(url, "\(failed.label) failed (\(errorText)) — all sources exhausted", level: "WARN")
            // Surface it: without this the views can only show a black frame.
            VideoPlaybackFailures.shared.mark(url)
            return
        }

        let next = ladder.candidates[ladder.index]
        log(url, "\(failed.label) failed (\(errorText)) → trying \(next.label)", level: "WARN")
        player.replaceCurrentItem(with: makeItem(for: next))
        attach(ladder, to: player)
        player.play()
    }

    /// Drops ladder state for a URL. Called when the player cache evicts its
    /// player (LRU, memory pressure, or explicit removal).
    func invalidateLadder(for url: URL) {
        lock.lock()
        let ladder = ladders.removeValue(forKey: url)
        // The local-copy veto lives exactly as long as the ladder that set it.
        // The bad copy was already discarded/quarantined when we set the flag,
        // so a later attempt either finds no local file or a fresh one — and a
        // fresh hash-named copy is integrity-checked before it is offered.
        // Keeping the veto past teardown stranded the URL on the network for
        // the rest of the process lifetime.
        skipLocal.remove(url)
        lock.unlock()
        ladder?.tearDown()
    }

    // MARK: Policy

    @MainActor
    private func applyAudioSession(for intent: Intent) {
        switch intent {
        case .inline:
            // Feed cells keep building inline players underneath a full-screen
            // or PiP video (see VideoPlayerCache.store). Letting them switch the
            // session back to mixing would strip exclusive audio from the video
            // the user is actually watching, so leave it alone while one owns it.
            guard !ownsExclusiveAudio else { return }
            AudioSessionManager.shared.enableMixingWithOthers()
        case .fullScreen, .standalone:
            AudioSessionManager.shared.enablePlayback()
        }
    }

    /// True while a full-screen or PiP video owns the audio session.
    @MainActor
    private var ownsExclusiveAudio: Bool {
        if VideoPlayerCache.shared.activeFullScreenURL != nil { return true }
        #if os(iOS)
        if PiPManager.shared.isPiPActive { return true }
        #endif
        return false
    }

    private func applyMutePolicy(to player: AVPlayer, intent: Intent) {
        switch intent {
        case .inline:
            player.isMuted = true
        case .fullScreen:
            player.isMuted = false
            player.volume = 1.0
        case .standalone:
            player.isMuted = false
        }
    }

    // MARK: Diagnostics

    /// Playback decisions land in the in-app relay log — the on-device source
    /// of truth for "why doesn't this video play" (the device console is not
    /// reliably streamable).
    private func log(_ url: URL, _ message: String, level: String = "INFO") {
        let name = url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent
        let short = name.count > 22 ? "\(name.prefix(14))…\(name.suffix(6))" : name
        #if DEBUG
        print("VideoPlayback[\(short)]: \(message)")
        #endif
        Task { @MainActor in
            RelayProcessManager.shared.addLog("Video \(short): \(message)", level: level)
        }
    }
}
