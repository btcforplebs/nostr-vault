import SwiftUI
import WidgetKit

// MARK: - Live now
//
// People you follow who are live: picture, name, stream title; a tap opens
// the stream. Small is the newest stream, medium up to three. The rules are
// Your space's Live now panel's (`LiveNow.pick`); the difference is who asks.
// A stream starts and ends while the app is closed, so the app only hands
// over who you follow (`NVLiveHandoff`) and this provider asks the live
// relays itself -- when the app opens (it reloads every timeline) and on the
// widget's own refresh budget otherwise.

struct LiveNowEntry: TimelineEntry {
    enum State: Equatable {
        /// The app has never handed anything over.
        case neverRun
        case followsNobody
        /// No relay answered: say so rather than claim nobody is live.
        case unreachable
        /// The streams drawn, and how many are live in all.
        case live([NVLiveTile], total: Int)
    }

    let date: Date
    let state: State
    /// Avatar bytes keyed by host pubkey, fetched before the body runs.
    let avatars: [String: Data]
}

struct LiveNowProvider: TimelineProvider {
    /// Asking again sooner than this would spend the day's reload budget by
    /// lunch; the app's own reloads on open fill the gaps.
    private static let refreshEvery: TimeInterval = 15 * 60
    private static let askTimeout: TimeInterval = 6
    private static let profileTimeout: TimeInterval = 4

    func placeholder(in context: Context) -> LiveNowEntry { .preview }

    func getSnapshot(in context: Context, completion: @escaping (LiveNowEntry) -> Void) {
        if context.isPreview { completion(.preview); return }
        Task { completion(await entry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LiveNowEntry>) -> Void) {
        Task {
            let entry = await entry()
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(Self.refreshEvery))))
        }
    }

    private func entry() async -> LiveNowEntry {
        let now = Date()
        guard let handoff = NVLiveNowStore.load(), handoff.generatedAt != .distantPast else {
            return LiveNowEntry(date: now, state: .neverRun, avatars: [:])
        }
        guard !handoff.follows.isEmpty else {
            return LiveNowEntry(date: now, state: handoff.followListIsKnown ? .followsNobody : .neverRun, avatars: [:])
        }

        let relays = NVLiveNowLogic.askableRelays(handoff.relays)
        let answer = await NVRelayAsk.ask(relays, filters: NVLiveNowLogic.streamFilters(follows: handoff.follows),
                                          timeout: Self.askTimeout)
        guard answer.answered > 0 || !answer.events.isEmpty else {
            return LiveNowEntry(date: now, state: .unreachable, avatars: [:])
        }

        let events: [LiveStatusBook.Event] = answer.events.compactMap { raw in
            guard raw["kind"] as? Int == 30311,
                  let id = raw["id"] as? String, let pubkey = raw["pubkey"] as? String,
                  let createdAt = (raw["created_at"] as? NSNumber)?.int64Value,
                  let tags = raw["tags"] as? [[String]] else { return nil }
            return LiveStatusBook.Event(id: id, pubkey: pubkey, createdAt: createdAt, tags: tags)
        }
        let all = LiveNow.pick(events, follows: Set(handoff.follows), blocked: Set(handoff.blocked),
                               now: Int64(now.timeIntervalSince1970))
        let picked = Array(all.prefix(NVLiveNowLogic.rows(isSmall: false)))
        guard !picked.isEmpty else { return LiveNowEntry(date: now, state: .live([], total: 0), avatars: [:]) }

        // Names and pictures: one kind 0 ask for the (at most three) hosts.
        let hosts = Array(Set(picked.map(\.host)))
        let profiles = await NVRelayAsk.ask(relays, filters: [["kinds": [0], "authors": hosts, "limit": hosts.count * 2]],
                                            timeout: Self.profileTimeout)
        var newest: [String: (createdAt: Int64, content: String)] = [:]
        for raw in profiles.events {
            guard raw["kind"] as? Int == 0, let pubkey = raw["pubkey"] as? String,
                  let createdAt = (raw["created_at"] as? NSNumber)?.int64Value,
                  let content = raw["content"] as? String else { continue }
            if let have = newest[pubkey], have.createdAt >= createdAt { continue }
            newest[pubkey] = (createdAt, content)
        }

        let tiles: [NVLiveTile] = picked.compactMap { event in
            guard let link = NVLiveLink.url(id: event.id, pubkey: event.pubkey,
                                            createdAt: event.createdAt, tags: event.tags) else { return nil }
            let profile = newest[event.host].map { NVLiveNowLogic.profile(fromContent: $0.content) }
            let title = event.tags.first { $0.count >= 2 && $0[0] == "title" }?[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return NVLiveTile(id: event.address ?? event.id,
                              hostPubkey: event.host,
                              name: profile?.name ?? NVLiveNowLogic.fallbackName(event.host),
                              pictureURL: profile?.picture,
                              title: (title?.isEmpty == false ? title : nil) ?? "Live now",
                              link: link)
        }

        let avatars = await NVTileFetcher.fetch(tiles.compactMap { tile in tile.pictureURL.map { (tile.hostPubkey, $0) } },
                                                maxPixel: 128, limit: 3)
        return LiveNowEntry(date: now, state: .live(tiles, total: all.count), avatars: avatars)
    }
}

struct LiveNowView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LiveNowEntry

    var body: some View {
        switch entry.state {
        case .neverRun:
            NVEmptyState(icon: "dot.radiowaves.left.and.right", message: "Open Nostr Vault to see who's live")
        case .followsNobody:
            NVEmptyState(icon: "dot.radiowaves.left.and.right", message: LiveNow.emptyLine(followsSomeone: false))
        case .unreachable:
            NVEmptyState(icon: "wifi.exclamationmark", message: "Can't reach the live relays right now")
        case .live(let tiles, _) where tiles.isEmpty:
            NVEmptyState(icon: "dot.radiowaves.left.and.right", message: LiveNow.emptyLine(followsSomeone: true))
        case .live(let tiles, let total):
            if family == .systemSmall, let first = tiles.first {
                SmallLive(tile: first, avatar: entry.avatars[first.hostPubkey], more: total - 1)
                    .widgetURL(first.link)
            } else {
                MediumLive(tiles: Array(tiles.prefix(NVLiveNowLogic.rows(isSmall: false))), avatars: entry.avatars)
            }
        }
    }
}

/// One stream, picture first: on a small square the face is what tells you
/// who it is at a glance, so it gets the room and the title gets two lines.
private struct SmallLive: View {
    let tile: NVLiveTile
    let avatar: Data?
    let more: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                LiveAvatar(data: avatar, seed: tile.hostPubkey, size: 50)
                Spacer(minLength: 0)
                // The count rides under the pill: a line of its own under the
                // title clipped on a small square once the title took two.
                VStack(alignment: .trailing, spacing: 4) {
                    LivePill()
                    if more > 0 {
                        Text("+\(more)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                            .accessibilityHidden(true)
                    }
                }
            }
            Spacer(minLength: 6)
            Text(tile.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(tile.title)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(tile.name) is live: \(tile.title)."
                            + (more > 0 ? " \(more) more live." : "") + " Opens the stream")
    }
}

/// Up to three rows, each its own tap target, spread over the height so one
/// or two streams do not huddle at the top of an empty box.
private struct MediumLive: View {
    let tiles: [NVLiveTile]
    let avatars: [String: Data]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.red)
                // Explicit, not .secondary: the ground is always dark, and in
                // light mode .secondary is a dark grey on it.
                Text("Live now")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
            }
            Divider().overlay(Color.white.opacity(0.08)).padding(.vertical, 5)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(tiles) { tile in
                    Link(destination: tile.link) {
                        HStack(spacing: 9) {
                            LiveAvatar(data: avatars[tile.hostPubkey], seed: tile.hostPubkey, size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(tile.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text(tile.title)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.75))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            LivePill()
                        }
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel("\(tile.name) is live: \(tile.title). Opens the stream")
                }
                if tiles.count < 3 { Spacer(minLength: 0) }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct LivePill: View {
    var body: some View {
        Text("LIVE")
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.red))
            .accessibilityHidden(true)
    }
}

/// The app's red live ring around the picture; a seeded hue when there is none.
private struct LiveAvatar: View {
    let data: Data?
    let seed: String
    let size: CGFloat

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Circle().fill(LinearGradient(colors: [hue.opacity(0.9), hue.opacity(0.45)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.red, lineWidth: max(2, size / 18)))
    }

    private var hue: Color {
        let value = seed.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Color(hue: Double(value % 360) / 360, saturation: 0.55, brightness: 0.85)
    }
}

extension LiveNowEntry {
    /// The widget gallery draws this before anything has been handed over.
    static let preview = LiveNowEntry(date: Date(), state: .live([
        NVLiveTile(id: "1", hostPubkey: "a1", name: "NoGood Radio", pictureURL: nil,
                   title: "Late night beats, all request", link: NVDeepLink.feed.url),
        NVLiveTile(id: "2", hostPubkey: "b2", name: "Satoshi's Kitchen", pictureURL: nil,
                   title: "Sourdough and sats", link: NVDeepLink.feed.url),
        NVLiveTile(id: "3", hostPubkey: "c3", name: "Relay Talk", pictureURL: nil,
                   title: "Outbox model Q&A", link: NVDeepLink.feed.url),
    ], total: 3), avatars: [:])
}

struct LiveNowWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LiveNow", provider: LiveNowProvider()) { entry in
            LiveNowView(entry: entry)
                .containerBackground(NV.background, for: .widget)
        }
        .configurationDisplayName("Live now")
        .description("People you follow who are live. Tap to watch.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
