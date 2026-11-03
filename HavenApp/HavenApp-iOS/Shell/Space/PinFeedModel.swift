import Foundation
import Combine

/// The notes behind a pinned list or relay on the iPad rail: a list's people
/// (NIP-51 follow set or follow pack, read fresh each time, so edits to the
/// list in any app show) or everything one relay has, newest first. One page;
/// blocked and muted people and spam are left out, and a relay's notes sit
/// behind the same Web of Trust shield as Global.
@MainActor
final class PinFeedModel: ObservableObject {
    enum Source: Equatable {
        case list(kind: Int, owner: String, d: String)
        case relay(String)
    }

    @Published private(set) var notes: [FeedNote] = []
    @Published private(set) var isLoading = true
    @Published private(set) var title: String?
    /// Set when the list could not be found or has no one on it.
    @Published private(set) var problem: String?

    let source: Source
    private var clients: [WebSocketClient] = []
    private var cancellables = Set<AnyCancellable>()
    private var seen = Set<String>()
    private var generation = 0

    static let pageSize = 60
    static let maxAuthors = 500
    /// Above this your web filters what the relay sends instead of going in the REQ (relays cap message size).
    static let maxTrustAuthors = 500

    init(source: Source) { self.source = source }

    static func source(for kind: SpaceLayout.Pin.Kind) -> Source? {
        switch kind {
        case .relay(let url): return .relay(url)
        case .list(let a):
            let parts = a.split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let kind = Int(parts[0]) else { return nil }
            return .list(kind: kind, owner: parts[1], d: parts[2])
        default: return nil
        }
    }

    func start() {
        stop()
        generation &+= 1
        let gen = generation
        notes = []
        seen = []
        isLoading = true
        problem = nil
        switch source {
        case .relay(let url):
            title = URL(string: url)?.host ?? url
            // With the shield on, ask the relay for your web's notes: its
            // newest page from everyone would rarely hold any of them.
            let trust = FeedService.shared.globalTrustSet()
            var filter: [String: Any] = ["kinds": [1], "limit": Self.pageSize]
            if let trust, !trust.isEmpty, trust.count <= Self.maxTrustAuthors { filter["authors"] = Array(trust) }
            subscribe(filter: filter, relays: [url], authors: nil, trust: trust, gen: gen)
        case .list(let kind, let owner, let d):
            Task {
                let lookup = await NostrService.shared.lookupNewestReplaceable(
                    kind: kind, for: owner, alsoAsk: ConfigService.shared.config.readRelays, dTag: d)
                guard gen == generation else { return }
                guard let event = lookup.event else {
                    problem = lookup.answered > 0 ? "This list wasn't found on your relays." : "Your relays didn't answer."
                    isLoading = false
                    return
                }
                title = event.tags.first { $0.count >= 2 && ($0[0] == "title" || $0[0] == "name") }?[1] ?? d
                let people = Array(Set(event.tags.filter { $0.count >= 2 && $0[0] == "p" }.map { $0[1].lowercased() }))
                guard !people.isEmpty else {
                    problem = "No one is on this list yet."
                    isLoading = false
                    return
                }
                let authors = Array(people.prefix(Self.maxAuthors))
                subscribe(filter: ["kinds": [1], "authors": authors, "limit": Self.pageSize],
                          relays: ConfigService.shared.config.activeFeedRelays, authors: Set(authors), trust: nil, gen: gen)
            }
        }
    }

    func stop() {
        clients.forEach { $0.disconnect() }
        clients = []
        cancellables = []
    }

    private func subscribe(filter: [String: Any], relays: [String], authors: Set<String>?, trust: Set<String>?, gen: Int) {
        let subId = "pin-\(UUID().uuidString.prefix(8))"
        guard let data = try? JSONSerialization.data(withJSONObject: ["REQ", subId, filter] as [Any]),
              let req = String(data: data, encoding: .utf8) else { return }
        let blocked = ConfigService.shared.activeAccountBlockedHexPubkeys
        let mutes = MuteListStore.shared.active
        let urls = relays.compactMap(URL.init(string:))
        if urls.isEmpty { isLoading = false }
        for url in urls {
            let client = WebSocketClient()
            client.isTemporary = true
            clients.append(client)
            var sent = false
            client.$connectionState
                .sink { [weak client] state in
                    guard state == .connected, !sent, let client else { return }
                    sent = true
                    client.send(text: req)
                }
                .store(in: &cancellables)
            client.messageSubject
                .compactMap { Self.parse($0, subId: subId, blocked: blocked, mutes: mutes, authors: authors, trust: trust) }
                .receive(on: DispatchQueue.main)
                .sink { [weak self] parsed in
                    guard let self, self.generation == gen else { return }
                    if let note = parsed { self.insert(note) } else { self.isLoading = false }
                }
                .store(in: &cancellables)
            client.connect(url: url)
        }
        // Never spin forever if every relay is slow or down.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.generation == gen else { return }
            self.isLoading = false
        }
    }

    private func insert(_ note: FeedNote) {
        guard seen.insert(note.id).inserted else { return }
        let i = notes.firstIndex { $0.createdAt < note.createdAt } ?? notes.endIndex
        notes.insert(note, at: i)
        isLoading = false
    }

    /// An EVENT for `subId` as a note (`.some(note)`), its EOSE (`.some(nil)`), else nil.
    nonisolated private static func parse(_ message: String, subId: String, blocked: Set<String>, mutes: MuteList,
                                          authors: Set<String>?, trust: Set<String>?) -> FeedNote?? {
        guard let data = message.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = array.first as? String,
              array.count >= 2, (array[1] as? String) == subId else { return nil }
        if type == "EOSE" { return .some(nil) }
        guard type == "EVENT", array.count >= 3,
              let ev = array[2] as? [String: Any],
              let id = ev["id"] as? String,
              let pubkey = ev["pubkey"] as? String,
              let content = ev["content"] as? String,
              let createdAt = ev["created_at"] as? Int64,
              let kind = ev["kind"] as? Int, kind == 1,
              let tags = ev["tags"] as? [[String]],
              !blocked.contains(pubkey),
              authors.map({ $0.contains(pubkey) }) ?? true,
              trust.map({ $0.contains(pubkey) }) ?? true,
              !FeedNote.isNoiseOrSpam(content: content, tags: tags),
              !mutes.hides(id: id, content: content, tags: tags),
              NostrEventVerifier.isValid(ev) else { return nil }
        return .some(FeedNote(id: id, pubkey: pubkey, content: content,
                              createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
                              tags: tags, kind: kind))
    }
}
