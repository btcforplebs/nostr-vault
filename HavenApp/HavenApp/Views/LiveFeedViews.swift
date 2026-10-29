import SwiftUI
import AVFoundation

/// One tile in the Live grid: thumbnail, a LIVE pill, and the viewer count when
/// the host publishes one.
struct LiveStreamCardView: View {
    let stream: LiveStream
    let profile: FeedProfile?
    /// False draws an ENDED pill — a stream embedded in a note outlives its
    /// broadcast, unlike a Live-tab tile.
    var isLive: Bool = true
    var thumbnailHeight: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                LiveStreamThumbnail(urls: stream.previewImageURLs)
                .frame(height: thumbnailHeight)
                .frame(maxWidth: .infinity)
                .clipped()

                HStack(spacing: 6) {
                    if isLive { livePill } else { endedPill }
                    if isLive, let participants = stream.participants {
                        Label("\(participants)", systemImage: "person.2.fill")
                            .font(.appSystem(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.55))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                }
                .padding(8)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(stream.title ?? "Untitled stream")
                    .font(.appSystem(size: 14, weight: .bold))
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(profile?.bestName ?? "npub…" + String(stream.hostPubkey.suffix(6)))
                    .font(.appSystem(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .padding(10)
        }
        .background(Color.controlBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.platformSeparator, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }

    private var endedPill: some View {
        Text("ENDED")
            .font(.appSystem(size: 10, weight: .bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.55))
            .foregroundColor(.white.opacity(0.8))
            .clipShape(Capsule())
    }

    private var livePill: some View {
        HStack(spacing: 4) {
            Circle().fill(Color.red).frame(width: 6, height: 6)
            Text("LIVE").font(.appSystem(size: 10, weight: .bold))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.black.opacity(0.55))
        .foregroundColor(.white)
        .clipShape(Capsule())
    }
}

/// A live tile's picture: the stream's live frame, else its cover art, else a
/// placeholder.
///
/// Not `RetryableAsyncImage`, which keeps every picture on disk by URL for
/// good. Cloudflare Stream and the fly.dev radio hosts serve each new frame at
/// one fixed URL, so the first frame ever fetched stayed on the tile forever;
/// and a cover that failed to load drew a "Media Missing / Error 404" card on
/// a stream that was playing fine. A stream's picture is only true while it is
/// on air, so it is kept in memory for a minute and then fetched again.
struct LiveStreamThumbnail: View {
    let urls: [URL]
    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            // Many streams publish no picture at all, so this is a common
            // case, not only a fallback.
            Rectangle().fill(Color.havenPurplePale)
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.appSystem(size: 28))
                .foregroundColor(.havenPurple.opacity(0.7))
            if let image {
                // An overlay on a clear rectangle, so a fill-scaled picture is
                // cropped to the tile instead of widening it.
                Color.clear
                    .overlay {
                        Image(platformImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
                    .transition(.opacity)
            }
        }
        .task(id: urls) {
            // Again every minute while the tile is on screen, so a fixed-URL
            // frame moves on too; the task ends when the tile goes.
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(LiveThumbnailCache.maxAge))
            }
        }
    }

    private func load() async {
        let cache = LiveThumbnailCache.shared
        if let held = cache.entry(for: urls) {
            image = held.image
            if held.isFresh { return }
        }
        for url in urls {
            if Task.isCancelled { return }
            guard let fetched = await cache.fetch(url) else { continue }
            if Task.isCancelled { return }
            withAnimation(Motion.fade) { image = fetched }
            return
        }
    }
}

/// Live-tile pictures, in memory only (see `LiveStreamThumbnail`).
@MainActor
final class LiveThumbnailCache {
    static let shared = LiveThumbnailCache()
    static let maxAge: TimeInterval = 60

    struct Entry {
        let image: PlatformImage
        let fetchedAt: Date
        var isFresh: Bool { Date().timeIntervalSince(fetchedAt) < LiveThumbnailCache.maxAge }
    }

    private var entries: [URL: Entry] = [:]

    /// The best picture already held for these candidates, in their order.
    func entry(for urls: [URL]) -> Entry? {
        urls.lazy.compactMap { self.entries[$0] }.first
    }

    /// Fetches past every HTTP cache — a fixed-URL frame must be new each time.
    /// zap.stream serves its `thumb.webp` as application/octet-stream, so the
    /// bytes decide what it is, not the content type.
    func fetch(_ url: URL) async -> PlatformImage? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let image = await ImageDownsampler.downsample(data: data, maxDimension: 600)
        else { return nil }
        if entries.count > 200 { entries.removeAll() }
        entries[url] = Entry(image: image, fetchedAt: Date())
        return image
    }
}

// MARK: - In a note

/// A live stream inside a note — quoted with `nostr:naddr1…` or linked from
/// zap.stream and friends. The Live-tab tile, so a stream looks the same
/// wherever it shows up, and a tap opens the same player.
struct LiveStreamEmbedView: View {
    let stream: LiveStream

    @EnvironmentObject var nostrService: NostrService
    @State private var playing: LiveStream?

    var body: some View {
        // Read once per render: an embed scrolled back to after its stream
        // ended must stop offering to play it.
        let isLive = stream.isPlayableLive(at: Int64(Date().timeIntervalSince1970))
        LiveStreamCardView(
            stream: stream,
            profile: nostrService.profiles[stream.hostPubkey],
            isLive: isLive,
            thumbnailHeight: 170
        )
        .opacity(isLive ? 1 : 0.75)
        .onTapGesture { if isLive { playing = stream } }
        .accessibilityAddTraits(isLive ? .isButton : [])
        .accessibilityHint(isLive ? Text("Plays the live stream") : Text("This stream has ended"))
        .sheet(item: $playing) { stream in
            LiveStreamPlayerView(stream: stream)
                .environmentObject(nostrService)
                .environmentObject(ConfigService.shared)
        }
    }
}

extension LiveStream {
    /// A stream from a note-shaped event, as quotes and the feed store it.
    init?(note: FeedNote) {
        guard note.kind == 30311 else { return nil }
        self.init(id: note.id, pubkey: note.pubkey,
                  createdAt: Int64(note.createdAt.timeIntervalSince1970), tags: note.tags)
    }
}

/// A stream known only by its coordinate, as a link names it: fetched through
/// the same lookup quoted notes use, then embedded.
struct LiveStreamReferenceView: View {
    let coordinate: String
    let fallbackURL: URL

    @EnvironmentObject var nostrService: NostrService
    @ObservedObject private var feedService = FeedService.shared

    var body: some View {
        if let note = feedService.findNote(id: coordinate), LiveStream(note: note) != nil {
            // Drawn as a quote so a blocked streamer's stream stays hidden.
            QuotedNoteView(note: note)
        } else if feedService.unavailableNoteIds.contains(coordinate) {
            LinkFallbackCard(url: fallbackURL)
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.platformTertiaryGroupedBackground)
                .frame(height: 230)
                .onAppear { feedService.fetchMissingNote(id: coordinate) }
        }
    }
}
