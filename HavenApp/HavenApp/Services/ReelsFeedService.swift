import Foundation
import Combine

/// Reels: one playable video per page, swiped vertically.
///
/// Two sources feed it. NIP-71 video events (kinds 21/22 and their addressable
/// 34235/34236 forms) are video by definition. Ordinary kind-1 notes are where
/// most video on Nostr actually lives, so they are fetched too and kept only
/// when a URL in them is known to be video — by extension or by the `m` field
/// of its NIP-92 `imeta` tag. Extensionless links with no MIME hint are left
/// out rather than HEAD-requested one by one: a page that turns out to be an
/// image is worse than a missing one.
@MainActor
final class ReelsFeedService: ObservableObject {
    static let shared = ReelsFeedService()

    /// Playable reels in play order.
    @Published private(set) var reels: [Reel] = []
    /// The first page is still being fetched.
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var loadFailed = false
    @Published private(set) var followSetIsEmpty = false
    /// Following by default. Global video is unmoderated third-party content,
    /// so it is opt-in behind the sensitive-content warning, like Media.
    @Published private(set) var scope: RecipeScope = .following

    static let videoKinds = [21, 22, 34235, 34236]

    /// The two filters a page asks for. Each pages on its own cursor: kind-1
    /// notes are dense and NIP-71 events are sparse, so one shared cursor would
    /// either skip notes or re-ask for the same video window.
    private enum Stream: CaseIterable { case video, note }

    private var clients: [WebSocketClient] = []
    private var cancellables = Set<AnyCancellable>()
    private var collected: [String: Reel] = [:]
    private var seenVideoURLs: Set<String> = []
    private var loadTimeout: Timer?
    private var publishWork: DispatchWorkItem?
    /// Once the viewer has swiped past the first reel the order is frozen:
    /// arrivals are appended instead of sorted in, so the video under their
    /// thumb never jumps.
    private var orderIsFrozen = false
    private var shownReelId: String?

    /// Where the next page starts, per stream. A stream missing from the map
    /// has run out of history.
    private var cursors: [Stream: Int64] = [:]
    private var exhausted: Set<Stream> = []
    /// Per relay, per stream: the oldest event this page returned.
    private var pageOldest: [Int: [Stream: Int64]] = [:]
    private var eoseThisFetch = 0
    private var countBeforeFetch = 0
    /// Consecutive pages that produced no reel; stops a video-less stretch of
    /// history from paging forever.
    private var emptyPages = 0
    private var isFetching: Bool { !clients.isEmpty }
    private var reachedEnd: Bool { exhausted.count == Stream.allCases.count || emptyPages >= 4 }

    private init() {}

    func setScope(_ newScope: RecipeScope) {
        guard newScope != scope else { return }
        scope = newScope
        refresh()
    }

    func loadIfNeeded() {
        guard !isFetching, reels.isEmpty else { return }
        refresh()
    }

    func refresh() {
        disconnect()
        collected.removeAll()
        seenVideoURLs.removeAll()
        reels = []
        orderIsFrozen = false
        shownReelId = nil
        cursors.removeAll()
        exhausted.removeAll()
        emptyPages = 0
        loadFailed = false
        followSetIsEmpty = false
        isLoadingMore = false
        isLoading = true
        fetch()
    }

    /// Called by the view as the viewer nears the end of what is loaded. A
    /// page still in flight is left alone — starting another would cut off
    /// the relays that have not answered yet.
    func loadMore() {
        guard !isFetching, !reachedEnd, !reels.isEmpty else { return }
        isLoadingMore = true
        fetch()
    }

    /// The view reports the reel on screen; leaving the first one freezes order.
    func didShow(reelId: String) {
        shownReelId = reelId
        if !orderIsFrozen, let first = reels.first, first.id != reelId {
            orderIsFrozen = true
        }
    }

    func disconnect() {
        loadTimeout?.invalidate()
        loadTimeout = nil
        publishWork?.cancel()
        publishWork = nil
        cancellables.removeAll()
        clients.forEach { $0.disconnect() }
        clients.removeAll()
    }

    /// Drops reels by anyone blocked since they were fetched. Cheap enough to
    /// run whenever a sheet that can block (a profile) closes.
    func pruneBlocked() {
        let blocked = ConfigService.shared.activeAccountBlockedHexPubkeys
        guard !blocked.isEmpty, reels.contains(where: { blocked.contains($0.note.pubkey) }) else { return }
        collected = collected.filter { !blocked.contains($0.value.note.pubkey) }
        reels = reels.filter { !blocked.contains($0.note.pubkey) }
    }

    // MARK: - Fetching

    private func fetch() {
        disconnect()

        var authors: [String]?
        if scope == .following {
            let follows = FeedService.shared.followedPubkeys
            guard !follows.isEmpty else {
                isLoading = false
                isLoadingMore = false
                followSetIsEmpty = true
                return
            }
            authors = follows
        }

        var filters: [[String: Any]] = []
        for stream in Stream.allCases where !exhausted.contains(stream) {
            var filter: [String: Any] = stream == .video
                ? ["kinds": Self.videoKinds, "limit": 100]
                : ["kinds": [1], "limit": 300]
            if let authors { filter["authors"] = authors }
            if let cursor = cursors[stream] { filter["until"] = cursor }
            filters.append(filter)
        }
        guard !filters.isEmpty else {
            isLoading = false
            isLoadingMore = false
            return
        }

        let relayURLs = Self.relayURLs(scope: scope)
        guard !relayURLs.isEmpty else {
            isLoading = false
            isLoadingMore = false
            loadFailed = true
            return
        }

        let subId = "reels-\(UUID().uuidString.prefix(8))"
        let blocked = ConfigService.shared.activeAccountBlockedHexPubkeys
        countBeforeFetch = collected.count
        eoseThisFetch = 0
        pageOldest.removeAll()

        for (relayIndex, url) in relayURLs.enumerated() {
            let client = WebSocketClient()
            client.isTemporary = true
            clients.append(client)

            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { [weak self] message in
                    self?.handle(message: message, relay: relayIndex, blocked: blocked)
                }
                .store(in: &cancellables)

            client.connect(url: url)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let req = ["REQ", subId] + filters.map { $0 as Any }
                if let data = try? JSONSerialization.data(withJSONObject: req),
                   let text = String(data: data, encoding: .utf8) {
                    client.send(text: text)
                }
            }
        }

        loadTimeout?.invalidate()
        loadTimeout = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.finishPage() }
        }
    }

    /// The device's own relay (and its feed cache) answer first and hold the
    /// follow set's history; the external relays fill in the rest.
    static func relayURLs(scope: RecipeScope) -> [URL] {
        var strings: [String] = []
        if scope == .following,
           RelayProcessManager.shared.isRunning,
           !RelayProcessManager.shared.isBooting {
            let local = ConfigService.shared.config.nostrURL
            strings += [local, local + "/feed"]
        }
        let configured = ConfigService.shared.config.activeFeedRelays
        strings += configured.isEmpty ? ["wss://relay.primal.net", "wss://nos.lol"] : configured
        var seen = Set<String>()
        return strings.filter { seen.insert($0).inserted }.compactMap { URL(string: $0) }
    }

    // MARK: - Private

    private func handle(message: String, relay: Int, blocked: Set<String>) {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = json.first as? String else { return }

        if type == "EOSE" {
            eoseThisFetch += 1
            // Every relay has answered — no reason to sit out the timeout.
            if eoseThisFetch >= clients.count { finishPage() } else { schedulePublish(immediate: true) }
            return
        }

        guard type == "EVENT", json.count >= 3,
              let event = json[2] as? [String: Any],
              let id = event["id"] as? String,
              let pubkey = event["pubkey"] as? String,
              let createdAt = event["created_at"] as? Int64,
              let kind = event["kind"] as? Int,
              let tags = event["tags"] as? [[String]],
              let content = event["content"] as? String,
              kind == 1 || Self.videoKinds.contains(kind)
        else { return }

        let stream: Stream = kind == 1 ? .note : .video
        pageOldest[relay, default: [:]][stream] = min(pageOldest[relay]?[stream] ?? createdAt, createdAt)

        guard !blocked.contains(pubkey), collected[id] == nil else { return }

        let note = FeedNote(
            id: id,
            pubkey: pubkey,
            content: content,
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
            tags: tags,
            kind: kind
        )
        guard let reel = Reel(note: note, createdAt: createdAt),
              seenVideoURLs.insert(reel.videoURL.absoluteString).inserted
        else { return }

        collected[id] = reel
        schedulePublish(immediate: false)
    }

    /// Events arrive one message at a time from several relays; batch them so
    /// the pager is not re-laid-out per event.
    private func schedulePublish(immediate: Bool) {
        publishWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.publish() }
        publishWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediate ? 0 : 0.35), execute: work)
    }

    private func publish() {
        if orderIsFrozen {
            let shown = Set(reels.map(\.id))
            let arrivals = collected.values
                .filter { !shown.contains($0.id) }
                .sorted(by: Reel.newestFirst)
            if !arrivals.isEmpty { reels.append(contentsOf: arrivals) }
        } else {
            reels = collected.values.sorted(by: Reel.newestFirst)
        }
    }

    private func finishPage() {
        guard isFetching else { return }
        publish()

        // No relay answered at all: a network failure, not the end of
        // history. Leave the cursors alone so a later swipe can retry.
        let gotAnything = !pageOldest.isEmpty
        if !gotAnything && eoseThisFetch == 0 {
            disconnect()
            isLoading = false
            isLoadingMore = false
            loadFailed = reels.isEmpty && !followSetIsEmpty
            return
        }

        // Next cursor per stream: the NEWEST of the relays' oldest events.
        // Taking the oldest overall would jump a dense relay past history a
        // sparse relay never had; this way every relay resumes where it
        // stopped, and the overlap is deduplicated by event id.
        for stream in Stream.allCases where !exhausted.contains(stream) {
            let oldest = pageOldest.values.compactMap { $0[stream] }
            if let resume = oldest.max() {
                cursors[stream] = resume - 1
            } else {
                exhausted.insert(stream)
            }
        }

        emptyPages = collected.count == countBeforeFetch ? emptyPages + 1 : 0
        disconnect()
        isLoading = false
        isLoadingMore = false
        loadFailed = false

        // Keep paging when the viewer is already near the end — a page of
        // notes with no video in it would otherwise park the pager on its last
        // reel with nothing left to trigger the next page.
        guard !reachedEnd else { return }
        let shownIndex = shownReelId.flatMap { id in reels.firstIndex { $0.id == id } } ?? 0
        if reels.isEmpty || shownIndex >= reels.count - 3 {
            if reels.isEmpty { isLoading = true } else { isLoadingMore = true }
            fetch()
        }
    }
}

/// One page of the Reels feed: a note and the single video it plays.
struct Reel: Identifiable, Equatable {
    let note: FeedNote
    let createdAt: Int64
    let videoURL: URL
    /// MIME from the event, for extensionless Blossom URLs.
    let mimeType: String?
    /// Poster frame the event publishes, shown until the video has a frame.
    let posterURL: URL?
    /// Width / height when the event says; otherwise learned from the player.
    let aspectRatio: CGFloat?
    let title: String?
    /// The note text with the video link itself taken out.
    let caption: String

    var id: String { note.id }

    static func == (lhs: Reel, rhs: Reel) -> Bool { lhs.id == rhs.id }

    static func newestFirst(_ a: Reel, _ b: Reel) -> Bool {
        if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
        return a.id > b.id
    }

    init?(note: FeedNote, createdAt: Int64) {
        // A note with a content warning autoplaying full-screen defeats the
        // warning, so those stay in the timeline where they can be blurred.
        if note.tags.contains(where: { $0.first == "content-warning" }) { return nil }

        let imeta = Self.imetaFields(note.tags)
        let isVideoEvent = ReelsFeedService.videoKinds.contains(note.kind)

        // First URL that is known to be video, in the order the note gives them.
        var pick: (url: URL, mime: String?)?
        for entry in imeta {
            guard let raw = entry["url"], let url = URL(string: raw), Self.isHTTP(url) else { continue }
            let mime = entry["m"]
            if let mime, mime.lowercased().hasPrefix("video/") { pick = (url, mime); break }
            if MediaKindResolver.cachedKind(for: url, mimeHint: mime) == .video { pick = (url, mime); break }
        }
        if pick == nil {
            for url in note.mediaURLs where Self.isHTTP(url) {
                if MediaKindResolver.cachedKind(for: url) == .video { pick = (url, nil); break }
            }
        }
        // Older NIP-71 events carry a bare `url` tag instead of imeta.
        if pick == nil, isVideoEvent,
           let raw = note.tags.first(where: { $0.count >= 2 && $0[0] == "url" })?[1],
           let url = URL(string: raw), Self.isHTTP(url) {
            let mime = note.tags.first(where: { $0.count >= 2 && $0[0] == "m" })?[1]
            pick = (url, mime)
        }
        guard let pick else { return nil }

        let entry = imeta.first { $0["url"] == pick.url.absoluteString }
        self.note = note
        self.createdAt = createdAt
        self.videoURL = pick.url
        self.mimeType = pick.mime
        self.posterURL = (entry?["image"] ?? entry?["thumb"]
            ?? note.tags.first(where: { $0.count >= 2 && ($0[0] == "image" || $0[0] == "thumb") })?[1])
            .flatMap { URL(string: $0) }
        self.aspectRatio = (entry?["dim"]).flatMap(Self.aspect(fromDim:))
        let title = note.tags.first(where: { $0.count >= 2 && $0[0] == "title" })?[1]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = (title?.isEmpty ?? true) ? nil : title
        self.caption = note.content
            .replacingOccurrences(of: pick.url.absoluteString, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isHTTP(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "https" || scheme == "http"
    }

    /// Each NIP-92 `imeta` tag as a field dictionary (`url`, `m`, `dim`, `image`…).
    private static func imetaFields(_ tags: [[String]]) -> [[String: String]] {
        tags.compactMap { tag in
            guard tag.first == "imeta", tag.count >= 2 else { return nil }
            var fields: [String: String] = [:]
            for field in tag.dropFirst() {
                guard let space = field.firstIndex(of: " ") else { continue }
                let key = String(field[..<space])
                let value = field[field.index(after: space)...].trimmingCharacters(in: .whitespaces)
                // First value wins — `image` and `fallback` may repeat.
                if fields[key] == nil, !value.isEmpty { fields[key] = value }
            }
            return fields
        }
    }

    /// `dim 1080x1920` → 0.5625.
    static func aspect(fromDim dim: String) -> CGFloat? {
        let parts = dim.lowercased().split(separator: "x")
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 0, h > 0 else { return nil }
        return CGFloat(w / h)
    }
}
