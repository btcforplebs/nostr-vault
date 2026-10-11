import SwiftUI
import Combine

/// Posts tagged with one hashtag (`#t`), newest first, live: the subscription
/// stays open so new posts arrive while the screen is up. Two groups: the
/// people you follow, then everyone else the shield lets through (your Web of
/// Trust, or everyone). Reaching the end of a group loads its next older page.
@MainActor
final class HashtagFeedModel: ObservableObject {
    /// The hashtags being shown. One for the sheet; the Hashtags feed swaps them.
    private(set) var tags: [String]
    @Published private(set) var fromFollows: [FeedNote] = []
    @Published private(set) var fromOthers: [FeedNote] = []
    @Published private(set) var isLoading = true
    /// The group whose older page is on its way, for the spinner under it.
    @Published private(set) var loadingOlder: Section?

    enum Section { case follows, others }

    private var clients: [WebSocketClient] = []
    private var cancellables = Set<AnyCancellable>()
    private var seen = Set<String>()
    private var follows = Set<String>()
    /// What the posts on hand were loaded for; see `start(follows:trust:)`.
    private var shownTags: [String] = []
    private var shownTrust: Set<String>?
    private let queue = DispatchQueue(label: "com.haven.hashtag-feed")
    private var generation = 0
    /// What `start` asked for, kept so an older page asks the same of each group.
    private var followsFilters: [[String: Any]] = []
    private var othersFilters: [[String: Any]] = []
    private var wantedTags = Set<String>()
    private var wantedAuthors: Set<String>?
    private var exhausted = Set<Section>()
    private var pageClients: [WebSocketClient] = []
    private var pageCancellables = Set<AnyCancellable>()
    private var page = 0
    /// Fill your feed: no web of trust yet, so the open list is screened
    /// (`TopicFeedFilter`). Every post lands in `pool`; `fromOthers` is what
    /// passes. Follow counts come from each author's kind 3.
    @Published private(set) var screening = false
    private var pool: [FeedNote] = []
    private var followCounts: [String: Int] = [:]
    private var lookingUp = Set<String>()
    /// Authors whose follow-count lookup timed out with no follow list found,
    /// and how often. See `followLookupTries`.
    private var timedOut: [String: Int] = [:]
    /// Lookups that timed out before an author with no follow list counts
    /// as following nobody. One slow relay must not hide a person for good,
    /// nor a dead one keep asking about them forever.
    private static let followLookupTries = 3
    /// Bumped by `stop()`: a lookup the view dropped (it went off screen)
    /// mustn't count as a timeout. `generation` alone only moves on `start()`.
    private var lookupGeneration = 0
    /// A relay has finished its first page. Screened, that alone isn't the
    /// end of loading: the posts on hand wait for their authors' follow
    /// counts, and an empty list until then is not "no posts".
    private var firstPageDone = false
    private var rescreenQueued = false
    private var lookupClients: [WebSocketClient] = []
    private var lookupCancellables = Set<AnyCancellable>()
    /// Who else liked, replied to, reposted or zapped each shown post.
    /// Posts people responded to go first (`TopicFeedFilter.ordered`).
    private var responders: [String: Set<String>] = [:]
    private var askedResponders = Set<String>()
    private var pendingResponders: [String] = []
    private var respondersQueued = false

    init(tag: String) { self.tags = [tag] }
    init(tags: [String]) { self.tags = tags }

    /// Same as `start(follows:trust:)` for a new set of hashtags.
    func start(tags: [String], follows: Set<String>, trust: Set<String>?, screen: Bool = false) {
        self.tags = tags
        start(follows: follows, trust: trust, screen: screen)
    }

    /// `follows` fill the top group. `trust` is who else may show: nil is
    /// everyone, empty is nobody (no Web of Trust yet fails closed, like Global).
    /// Everyone is one list by time: with follows on top, a busy follow list
    /// buried everyone else and the shield seemed to do nothing.
    func start(follows: Set<String>, trust: Set<String>?, screen: Bool = false) {
        stop()
        generation += 1
        let gen = generation
        if screen != screening {
            screening = screen
            pool = []
            fromOthers = []
            seen = []
        }
        // Same feed as last time (back from a note): keep the posts so the
        // list, and the scroll position on it, survive; the reopened
        // subscription only adds what is new.
        // Screened (Fill your feed), follows don't change what's shown: a
        // follow from the guide must not wipe and reload the list under the
        // reader (Logen, 2026-10-08).
        let sameFollows = follows == self.follows || (screen && trust == nil)
        let resuming = tags == shownTags && sameFollows && trust == shownTrust
            && !(fromFollows.isEmpty && fromOthers.isEmpty)
        shownTags = tags
        shownTrust = trust
        if !resuming {
            fromFollows = []
            fromOthers = []
            pool = []
            seen = []
            isLoading = true
            firstPageDone = false
        }
        self.follows = follows
        // stop() dropped any lookups in flight; ask again for what's on hand.
        if resuming && screening { queueRescreen() }
        // Filters are rebuilt below; a resumed list keeps what it learned about its end.
        followsFilters = []
        othersFilters = []
        if !resuming { exhausted = [] }

        // NIP-24 says t tags are lowercase; some clients keep the typed case.
        // Capped so the REQ stays under relay message limits.
        let wantedTags = Set(tags.prefix(Self.maxTags).flatMap { [$0, $0.lowercased()] })
        guard !wantedTags.isEmpty else {
            isLoading = false
            return
        }
        let base: [String: Any] = [
            "kinds": [1],
            "#t": Array(wantedTags).sorted(),
            "limit": tags.count > 1 ? 200 : 100,
        ]
        // Follows asked by name, so a busy tag cannot push them out of the page;
        // past the cap, the open filter finds them. Capped so the REQ stays
        // under relay message limits.
        if !follows.isEmpty {
            var byFollows = base
            byFollows["authors"] = Array(follows.sorted().prefix(FeedService.trustedAuthorsCap))
            followsFilters = [byFollows]
        }
        if let trust {
            let others = trust.subtracting(follows)
            if !others.isEmpty {
                othersFilters = FeedService.trustScopedFilters(base, trust: others)
            } else if follows.count > FeedService.trustedAuthorsCap {
                othersFilters = [base]
            }
        } else {
            othersFilters = [base]
        }
        let filters = followsFilters + othersFilters
        guard !filters.isEmpty else {
            isLoading = false
            return
        }
        let wantedAuthors = trust.map { $0.union(follows) }
        self.wantedTags = wantedTags
        self.wantedAuthors = wantedAuthors

        let subId = "hashtag-\(UUID().uuidString.prefix(8))"
        let message: [Any] = ["REQ", subId] + filters
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let req = String(data: data, encoding: .utf8) else { return }

        let relays = ConfigService.shared.config.activeFeedRelays.compactMap(URL.init(string:))
        let blocked = ConfigService.shared.activeAccountBlockedHexPubkeys
        for relay in relays {
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
                .receive(on: queue)
                .compactMap { message -> FeedNote?? in
                    Self.parse(message, subId: subId, blocked: blocked, tags: wantedTags, authors: wantedAuthors)
                }
                .receive(on: DispatchQueue.main)
                .sink { [weak self] parsed in
                    guard let self, self.generation == gen else { return }
                    switch parsed {
                    case .some(let note?): self.insert(note)
                    case .some(nil):   // EOSE from a relay
                        self.firstPageDone = true
                        if self.screening { self.endLoadingIfSettled() } else { self.isLoading = false }
                    case .none: break
                    }
                }
                .store(in: &cancellables)
            client.connect(url: relay)
        }
        // Never spin forever if every relay is slow or down.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.generation == gen else { return }
            self.isLoading = false
        }
    }

    static let maxTags = 100

    func stop() {
        clients.forEach { $0.disconnect() }
        clients = []
        cancellables.removeAll()
        lookupClients.forEach { $0.disconnect() }
        lookupClients = []
        lookupCancellables.removeAll()
        lookupGeneration += 1
        lookingUp = []
        askedResponders.subtract(askedResponders.filter { responders[$0] == nil })
        stopPage()
    }

    private func stopPage() {
        pageClients.forEach { $0.disconnect() }
        pageClients = []
        pageCancellables.removeAll()
        loadingOlder = nil
    }

    /// Call as each row shows. Near the end of its group, loads that group's
    /// next older page. Older posts only ever join the group being read, at
    /// its end, so nothing above the reader moves: an older post from someone
    /// you follow, found while paging the second group, waits for the first
    /// group's own page.
    func rowAppeared(_ note: FeedNote, in section: Section) {
        let list = section == .follows ? fromFollows : fromOthers
        guard let index = list.lastIndex(where: { $0.id == note.id }),
              index >= list.count - Self.pageAhead else { return }
        loadOlder(section)
    }

    /// The last card of a group showed (Threaded layout, where rows are
    /// conversations rather than single posts).
    func reachedEnd(of section: Section) {
        loadOlder(section)
    }

    private func loadOlder(_ section: Section) {
        // Screened, the oldest post asked for is in the pool, not the list.
        let list = section == .follows ? fromFollows : (screening ? pool : fromOthers)
        let base = section == .follows ? followsFilters : othersFilters
        guard loadingOlder == nil, !exhausted.contains(section),
              let oldest = list.last, !base.isEmpty else { return }
        // Inclusive, so posts sharing the oldest second are not skipped; seen drops repeats.
        let until = Int(oldest.createdAt.timeIntervalSince1970)
        let filters = base.map { filter -> [String: Any] in
            var paged = filter
            paged["until"] = until
            paged["limit"] = Self.pageSize
            return paged
        }
        let subId = "hashtag-older-\(UUID().uuidString.prefix(8))"
        let message: [Any] = ["REQ", subId] + filters
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let req = String(data: data, encoding: .utf8) else { return }

        let gen = generation
        page += 1
        let thisPage = page
        loadingOlder = section
        var added = 0
        var pending = Set<ObjectIdentifier>()
        let finish: () -> Void = { [weak self] in
            guard let self, self.generation == gen, self.page == thisPage, self.loadingOlder != nil else { return }
            if added == 0 { self.exhausted.insert(section) }
            self.stopPage()
        }
        let relays = ConfigService.shared.config.activeFeedRelays.compactMap(URL.init(string:))
        let blocked = ConfigService.shared.activeAccountBlockedHexPubkeys
        let wantedTags = wantedTags
        let wantedAuthors = wantedAuthors
        for relay in relays {
            let client = WebSocketClient()
            client.isTemporary = true
            pageClients.append(client)
            pending.insert(ObjectIdentifier(client))
            var sent = false
            client.$connectionState
                .sink { [weak client] state in
                    guard state == .connected, !sent, let client else { return }
                    sent = true
                    client.send(text: req)
                }
                .store(in: &pageCancellables)
            client.messageSubject
                .receive(on: queue)
                .compactMap { message -> FeedNote?? in
                    Self.parse(message, subId: subId, blocked: blocked, tags: wantedTags, authors: wantedAuthors)
                }
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak client] parsed in
                    guard let self, self.generation == gen, self.page == thisPage else { return }
                    switch parsed {
                    case .some(let note?):
                        if self.insertOlder(note, into: section) { added += 1 }
                    case .some(nil):
                        if let client { pending.remove(ObjectIdentifier(client)) }
                        if pending.isEmpty { finish() }
                    case .none: break
                    }
                }
                .store(in: &pageCancellables)
            client.connect(url: relay)
        }
        if relays.isEmpty { finish() }
        // A relay that never answers must not hold the next page forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: finish)
    }

    /// An older page's post, kept only if it belongs to the group being paged.
    private func insertOlder(_ note: FeedNote, into section: Section) -> Bool {
        // Same split as `insert`: with the shield off there is one list.
        let home: Section = shownTrust != nil && follows.contains(note.pubkey) ? .follows : .others
        guard home == section,
              seen.insert(note.id).inserted else { return false }
        if section == .others && screening {
            Self.insert(note, into: &pool)
            queueRescreen()
            return true
        }
        if section == .follows {
            Self.insert(note, into: &fromFollows)
        } else {
            Self.insert(note, into: &fromOthers)
        }
        return true
    }

    private static let pageSize = 100
    /// How many rows before a group's end its next page starts loading.
    private static let pageAhead = 5
    /// Per group, so a long read stays bounded. Live posts arrive at the top,
    /// so trimming drops the oldest, far below the reader.
    private static let maxNotes = 1500

    private func insert(_ note: FeedNote) {
        guard seen.insert(note.id).inserted else { return }
        if shownTrust != nil, follows.contains(note.pubkey) {
            Self.insert(note, into: &fromFollows)
        } else if screening {
            // Not shown yet: loading ends when the screen pass says so.
            Self.insert(note, into: &pool)
            queueRescreen()
            return
        } else {
            Self.insert(note, into: &fromOthers)
        }
        isLoading = false
    }

    /// Screened, loading ends once a relay's first page is in and every
    /// author on hand has been asked about. Before that an empty list read
    /// as "No posts tagged #x yet" for up to 6 s on a fresh install.
    private func endLoadingIfSettled() {
        if firstPageDone && lookingUp.isEmpty && !rescreenQueued { isLoading = false }
    }

    // MARK: Screening (Fill your feed)

    /// One pass per run-loop turn, however many posts arrived in it.
    private func queueRescreen() {
        guard !rescreenQueued else { return }
        rescreenQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rescreenQueued = false
            self.lookUpFollowCounts()
            self.rescreen()
        }
    }

    private func rescreen() {
        let posts = pool.map { TopicFeedFilter.Post(id: $0.id, pubkey: $0.pubkey, content: $0.content, tags: $0.tags) }
        let shownIds = TopicFeedFilter.shown(posts, followCounts: followCounts)
        lookUpResponders(shownIds)
        let byId = Dictionary(pool.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let counts = responders.mapValues(\.count)
        let next = TopicFeedFilter.ordered(shownIds, responders: counts).compactMap { byId[$0] }
        if next.map(\.id) != fromOthers.map(\.id) { fromOthers = next }
        if !next.isEmpty { isLoading = false }
        endLoadingIfSettled()
    }

    /// Replies, reposts, reactions and zaps on the shown posts, counted by
    /// distinct person (the author's own don't count).
    private func lookUpResponders(_ ids: [String]) {
        let fresh = ids.filter { !askedResponders.contains($0) }
        guard !fresh.isEmpty else { return }
        askedResponders.formUnion(fresh)
        pendingResponders.append(contentsOf: fresh)
        // Posts arrive in a stream: ask once a second, not once per post.
        guard !respondersQueued else { return }
        respondersQueued = true
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.respondersQueued = false
            let missing = self.pendingResponders
            self.pendingResponders = []
            guard self.generation == gen else {
                self.askedResponders.subtract(missing)
                return
            }
            self.askResponders(missing)
        }
    }

    private func askResponders(_ missing: [String]) {
        let authors = Dictionary(pool.map { ($0.id, $0.pubkey) }, uniquingKeysWith: { first, _ in first })
        let wanted = Set(missing)
        var found: [String: Set<String>] = [:]
        // One filter per 25 posts, because `limit` caps each filter and one
        // busy post must not use it up for the others; all of them in one
        // REQ, so one tick opens one connection per relay (Tron, 2026-10-08).
        let filters: [[String: Any]] = missing.chunked(into: 25).map {
            ["kinds": [1, 6, 7, 9735], "#e": $0, "limit": 1000]
        }
        oneShotQuery(filters, onEvent: { ev in
            guard let pubkey = TopicFeedFilter.responder(ev, isValid: NostrEventVerifier.isValid),
                  let tags = ev["tags"] as? [[String]] else { return }
            for tag in tags where tag.count >= 2 && tag[0] == "e" && wanted.contains(tag[1]) {
                if authors[tag[1]] != pubkey { found[tag[1], default: []].insert(pubkey) }
            }
        }, finish: { [weak self] _ in
            guard let self else { return }
            for id in missing { self.responders[id, default: []].formUnion(found[id] ?? []) }
            self.rescreen()
        })
    }

    /// One REQ to every feed relay; `finish` runs once, when all have
    /// answered (true) or after 6s (false), and only if the feed hasn't
    /// restarted since. Its sockets close when it finishes.
    private func oneShotQuery(_ filters: [[String: Any]], onEvent: @escaping ([String: Any]) -> Void,
                              finish: @escaping (_ complete: Bool) -> Void) {
        let gen = generation
        let lookupGen = lookupGeneration
        let subId = "q-\(UUID().uuidString.prefix(8))"
        // Always finish, so a lookup can't leave its authors in `lookingUp`.
        guard let data = try? JSONSerialization.data(withJSONObject: (["REQ", subId] as [Any]) + filters),
              let req = String(data: data, encoding: .utf8) else { finish(false); return }
        let relays = ConfigService.shared.config.activeFeedRelays.compactMap(URL.init(string:))
        var answered = Set<Int>()
        var finished = false
        var mine: [WebSocketClient] = []
        var mineCancellables: [AnyCancellable] = []
        let finishOnce = { [weak self] (complete: Bool) in
            guard !finished else { return }
            finished = true
            mine.forEach { $0.disconnect() }
            guard let self else { return }
            self.lookupClients.removeAll { client in mine.contains { $0 === client } }
            mineCancellables.forEach { $0.cancel(); self.lookupCancellables.remove($0) }
            guard self.generation == gen, self.lookupGeneration == lookupGen else { return }
            finish(complete)
        }
        for (index, relay) in relays.enumerated() {
            let client = WebSocketClient()
            client.isTemporary = true
            lookupClients.append(client)
            mine.append(client)
            var sent = false
            client.$connectionState
                .sink { [weak client] state in
                    guard state == .connected, !sent, let client else { return }
                    sent = true
                    client.send(text: req)
                }
                .store(in: &mineCancellables)
            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { message in
                    guard let data = message.data(using: .utf8),
                          let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
                          let type = array.first as? String, array.count >= 2,
                          (array[1] as? String) == subId else { return }
                    if type == "EVENT", array.count >= 3, let ev = array[2] as? [String: Any],
                       NostrEventVerifier.isValid(ev) {
                        onEvent(ev)
                    } else if type == "EOSE" || type == "CLOSED" {
                        // Per relay, so two frames from one can't end it early.
                        answered.insert(index)
                        if answered.count >= relays.count { finishOnce(true) }
                    }
                }
                .store(in: &mineCancellables)
            lookupCancellables.formUnion(mineCancellables.suffix(2))
            client.connect(url: relay)
        }
        if relays.isEmpty { finishOnce(true) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { finishOnce(false) }
    }

    /// Each new author's newest kind 3, counted. Authors no relay has a
    /// follow list for count as 0, which keeps them out: people follow. Only
    /// once every relay has answered, or after `followLookupTries` timed
    /// out; until then they wait as unknown and are asked again next pass.
    private func lookUpFollowCounts() {
        let missing = Array(Set(pool.map(\.pubkey)).subtracting(followCounts.keys).subtracting(lookingUp))
        guard !missing.isEmpty else { return }
        lookingUp.formUnion(missing)
        let wanted = Set(missing)
        var newest: [String: (Int64, Int)] = [:]
        let filters: [[String: Any]] = missing.chunked(into: 100).map { ["kinds": [3], "authors": $0] }
        oneShotQuery(filters, onEvent: { ev in
            guard let pubkey = ev["pubkey"] as? String, wanted.contains(pubkey),
                  let createdAt = ev["created_at"] as? Int64,
                  let tags = ev["tags"] as? [[String]],
                  (ev["kind"] as? Int) == 3 else { return }
            if (newest[pubkey]?.0 ?? 0) < createdAt {
                newest[pubkey] = (createdAt, tags.filter { $0.first == "p" }.count)
            }
        }, finish: { [weak self] complete in
            guard let self else { return }
            for author in missing where self.followCounts[author] == nil {
                let tries = (self.timedOut[author] ?? 0) + 1
                if let count = newest[author]?.1 {
                    self.followCounts[author] = count
                } else if complete || tries >= Self.followLookupTries {
                    self.followCounts[author] = 0
                } else {
                    self.timedOut[author] = tries
                }
                if self.followCounts[author] != nil { self.timedOut[author] = nil }
            }
            // Asked again on a timer, not only when another post arrives: on
            // a quiet tag that could be hours. The try cap ends it.
            if missing.contains(where: { self.followCounts[$0] == nil }) {
                let lookupGen = self.lookupGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, self.lookupGeneration == lookupGen else { return }
                    self.queueRescreen()
                }
            }
            self.lookingUp.subtract(missing)
            self.rescreen()
        })
    }

    private static func insert(_ note: FeedNote, into list: inout [FeedNote]) {
        let index = list.firstIndex { $0.createdAt < note.createdAt } ?? list.endIndex
        list.insert(note, at: index)
        if list.count > maxNotes { list.removeLast(list.count - maxNotes) }
    }

    /// `.some(note)` for a usable event, `.some(nil)` for EOSE, nil otherwise.
    /// Runs off the main thread: every event's signature is checked, since a
    /// relay can send anything under any author.
    /// Only what was asked for: a relay can send validly signed posts that
    /// lack the tag, or come from people outside the requested authors.
    nonisolated private static func parse(_ message: String, subId: String, blocked: Set<String>,
                                          tags wanted: Set<String>, authors: Set<String>?) -> FeedNote?? {
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
              tags.contains(where: { $0.count >= 2 && $0[0] == "t" && wanted.contains($0[1].lowercased()) }),
              !FeedNote.isNoiseOrSpam(content: content, tags: tags),
              NostrEventVerifier.isValid(ev) else { return nil }
        return .some(FeedNote(id: id, pubkey: pubkey, content: content,
                              createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
                              tags: tags, kind: kind))
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
