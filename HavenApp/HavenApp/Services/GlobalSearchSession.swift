import Foundation
import Combine

// MARK: - Public types

/// One row in Global search's per-source status strip.
struct GlobalSearchSourceStatus: Identifiable, Equatable {
    enum Role: Equatable { case device, mac, relay }

    let id: String
    let label: String
    let role: Role
    var state: GlobalSearchSourceState
    /// Results so far — shown while a slow source is still streaming.
    var count = 0
    /// How the source is being searched, when that is not obvious ("NIP-50",
    /// "paged"). Shown next to the Mac relay so it is clear which path ran.
    var detail: String?
}

/// Everything Global search knows at one moment. Published repeatedly while
/// sources answer, then once more with `isFinished`.
struct GlobalSearchSnapshot {
    var notes: [FeedNote] = []
    var profiles: [FeedProfile] = []
    var sources: [GlobalSearchSourceStatus] = []
    var isFinished = false
}

// MARK: - Search relay settings

/// The per-device list of NIP-50 search relays. Stored in UserDefaults rather
/// than `HavenConfig`: the relay never reads it, and a config change marks the
/// relay as needing a restart.
enum SearchRelaySettings {
    static var relays: [String] {
        get {
            SearchRelayDefaults.effective(
                stored: UserDefaults.standard.stringArray(forKey: SearchRelayDefaults.userDefaultsKey))
        }
        set {
            UserDefaults.standard.set(SearchRelayDefaults.normalized(newValue),
                                      forKey: SearchRelayDefaults.userDefaultsKey)
        }
    }

    static func resetToDefaults() {
        UserDefaults.standard.removeObject(forKey: SearchRelayDefaults.userDefaultsKey)
    }

    static var isDefault: Bool {
        UserDefaults.standard.object(forKey: SearchRelayDefaults.userDefaultsKey) == nil
    }
}

// MARK: - Session

/// One Global search: the device's own store, the Mac relay (when set) and every
/// search relay, all at once. Results are merged (deduped by event id / pubkey),
/// ranked, and published as they arrive; each source ends on its own EOSE /
/// CLOSED / error, and the whole search is capped at `hardCap`.
///
/// All state lives on `queue`. `onUpdate` is called on the main queue.
final class GlobalSearchSession {
    struct Request {
        var query: String
        var searchRelays: [URL]
        /// The device's embedded relay, or nil when it is not running.
        var deviceRelay: URL?
        /// false: leave the device store out entirely (mention lookup).
        var includeDevice = true
        var macRelay: URL?
        var cachedProfiles: [String: FeedProfile] = [:]
        var own: Set<String> = []
        var follows: Set<String> = []
    }

    /// No source is waited on longer than this. search.nos.today alone can take
    /// 4-16 s to answer.
    static let hardCap: TimeInterval = 15
    /// Coalesces bursts of events into one view update.
    static let publishInterval: TimeInterval = 0.15
    /// Most notes one update carries; the ranked tail is dropped.
    static let maxNotes = 200

    static let serviceNoteLimit = 50
    static let serviceProfileLimit = 20
    /// Own-store NIP-50 limits. Must stay <= 1000 (Badger's cap, see
    /// `LocalRelaySearchPlan`).
    static let macNoteLimit = 300
    static let macProfileLimit = 50

    #if os(macOS)
    static let deviceLabel = "This Mac"
    #else
    static let deviceLabel = "This device"
    #endif

    private let request: Request
    private let queue = DispatchQueue(label: "com.haven.global-search", qos: .userInitiated)
    private let onUpdate: (GlobalSearchSnapshot) -> Void
    private let ownStoreMatcher: LocalSearchMatcher?

    private var merge = GlobalSearchMerge<FeedNote, FeedProfile>()
    private var sourceOrder: [String] = []
    private var statuses: [String: GlobalSearchSourceStatus] = [:]
    private var progress: [String: GlobalSearchSourceProgress] = [:]
    /// Distinct results per source, for the "N found" count.
    private var sourceHits: [String: Set<String>] = [:]

    private struct Subscription {
        let sourceId: String
        let clientIndex: Int
        let verify: Bool
    }
    private var clients: [WebSocketClient] = []
    private var clientSubIds: [[String]] = []
    private var openSubs: [String: Subscription] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var localSessions: [LocalRelaySearchSession] = []
    private var infoTask: URLSessionDataTask?

    private var started = false
    private var finished = false
    private var publishScheduled = false

    private let cancelLock = NSLock()
    private var _cancelled = false
    private var isCancelled: Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }
        return _cancelled
    }

    init(request: Request, onUpdate: @escaping (GlobalSearchSnapshot) -> Void) {
        self.request = request
        self.onUpdate = onUpdate
        self.ownStoreMatcher = LocalSearchMatcher(allTermsOf: request.query)
    }

    func start() {
        queue.async { [weak self] in
            guard let self = self, !self.started, !self.isCancelled else { return }
            self.started = true
            self.startSources()
            self.publishNow()
            self.checkFinished()
        }
        queue.asyncAfter(deadline: .now() + Self.hardCap) { [weak self] in
            self?.hitHardCap()
        }
    }

    /// Stops every source. No update is delivered after this returns.
    func cancel() {
        cancelLock.lock()
        _cancelled = true
        cancelLock.unlock()
        queue.async { [weak self] in
            guard let self = self else { return }
            self.finished = true
            self.teardown()
        }
    }

    // MARK: Sources

    private func addSource(id: String, label: String, role: GlobalSearchSourceStatus.Role,
                           pending: Int, detail: String? = nil) {
        sourceOrder.append(id)
        statuses[id] = GlobalSearchSourceStatus(id: id, label: label, role: role,
                                                state: .searching, detail: detail)
        progress[id] = GlobalSearchSourceProgress(pending: pending)
        sourceHits[id] = []
    }

    private func startSources() {
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)

        if request.includeDevice {
            let id = "device"
            addSource(id: id, label: Self.deviceLabel, role: .device, pending: 1)
            if let base = request.deviceRelay, let matcher = ownStoreMatcher {
                startPaged(sourceId: id, base: base, matcher: matcher,
                           cachedProfiles: request.cachedProfiles)
            } else {
                progress[id]?.failed(reason: "relay not running", openReqs: 1)
                refreshStatus(id)
            }
        }

        if let mac = request.macRelay {
            let id = "mac"
            addSource(id: id, label: "Mac relay", role: .mac, pending: 1, detail: "checking")
            probeMac(sourceId: id, url: mac)
        }

        for relay in request.searchRelays {
            let id = "relay:" + relay.absoluteString
            guard statuses[id] == nil else { continue }
            addSource(id: id, label: relay.host ?? relay.absoluteString, role: .relay, pending: 0)
            // Separate REQs: a profile-only service CLOSES the notes REQ, and
            // with both filters in one REQ that killed its profiles too.
            openNIP50(sourceId: id, url: relay, verify: false, filters: [
                ["kinds": [1], "search": query, "limit": Self.serviceNoteLimit],
                ["kinds": [0], "search": query, "limit": Self.serviceProfileLimit]
            ])
        }
    }

    /// The Mac relay is searched server-side only if it says it can be: a relay
    /// without NIP-50 ignores `search` and would answer with its newest events.
    private func probeMac(sourceId: String, url: URL) {
        guard let infoURL = RelayInfoDocument.url(forRelay: url) else {
            startMacPaged(sourceId: sourceId, url: url, why: "paged")
            return
        }
        var req = URLRequest(url: infoURL, timeoutInterval: 5)
        req.setValue("application/nostr+json", forHTTPHeaderField: "Accept")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 6
        let session = URLSession(configuration: config)
        let task = session.dataTask(with: req) { [weak self] data, response, _ in
            session.finishTasksAndInvalidate()
            guard let self = self else { return }
            self.queue.async {
                guard !self.finished, !self.isCancelled else { return }
                let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
                if ok, let data, RelayInfoDocument.supportsNIP50(data) {
                    self.startMacNIP50(sourceId: sourceId, url: url)
                } else {
                    self.startMacPaged(sourceId: sourceId, url: url,
                                       why: ok ? "paged" : "paged, no NIP-11")
                }
                self.publishSoon()
            }
        }
        infoTask = task
        task.resume()
    }

    private func routes(for base: URL) -> [URL] {
        var root = base.absoluteString
        while root.hasSuffix("/") { root.removeLast() }
        return [root, root + "/feed", root + "/inbox"].compactMap { URL(string: $0) }
    }

    private func startMacNIP50(sourceId: String, url: URL) {
        statuses[sourceId]?.detail = "NIP-50"
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let routeURLs = routes(for: url)
        for route in routeURLs {
            openNIP50(sourceId: sourceId, url: route, verify: true, filters: [
                ["kinds": [1], "search": query, "limit": Self.macNoteLimit],
                ["kinds": [0], "search": query, "limit": Self.macProfileLimit]
            ])
        }
        // The subscriptions above replace the probe's one pending unit.
        progress[sourceId]?.resolve()
        refreshStatus(sourceId)
    }

    private func startMacPaged(sourceId: String, url: URL, why: String) {
        statuses[sourceId]?.detail = why
        guard let matcher = ownStoreMatcher else {
            progress[sourceId]?.failed(reason: "query too short", openReqs: 1)
            refreshStatus(sourceId)
            checkFinished()
            return
        }
        // The probe's pending unit becomes the paged session's.
        startPaged(sourceId: sourceId, base: url, matcher: matcher, cachedProfiles: [:])
    }

    /// Walks a haven relay's routes with until-cursors and matches on-device —
    /// the device's own store, or a Mac relay without NIP-50.
    private func startPaged(sourceId: String, base: URL, matcher: LocalSearchMatcher,
                            cachedProfiles: [String: FeedProfile]) {
        let session = LocalRelaySearchSession(matcher: matcher, routes: routes(for: base),
                                              timeout: Self.hardCap) { [weak self] results in
            guard let self = self else { return }
            self.queue.async {
                guard !self.finished else { return }
                self.ingest(results, sourceId: sourceId)
                self.refreshStatus(sourceId)
                self.publishSoon()
                self.checkFinished()
            }
        }
        session.onProgress = { [weak self] results in
            guard let self = self else { return }
            self.queue.async {
                guard !self.finished else { return }
                // A page came back: the source has answered, even if the cap
                // cuts the walk short later.
                self.progress[sourceId]?.markAnswered()
                self.ingest(results, sourceId: sourceId)
                self.refreshStatus(sourceId)
                self.publishSoon()
            }
        }
        session.onOutcome = { [weak self] outcome in
            guard let self = self else { return }
            self.queue.async {
                guard !self.finished else { return }
                if outcome.answered {
                    self.progress[sourceId]?.eose()
                } else {
                    self.progress[sourceId]?.failed(reason: outcome.reason ?? "no response", openReqs: 1)
                }
            }
        }
        if !cachedProfiles.isEmpty { session.addCachedProfiles(cachedProfiles) }
        localSessions.append(session)
        session.start()
    }

    private func ingest(_ results: GlobalSearchResults, sourceId: String) {
        for note in results.notes {
            merge.add(note: note, id: note.id)
            sourceHits[sourceId, default: []].insert(note.id)
        }
        for profile in results.profiles {
            merge.add(profile: profile, pubkey: profile.pubkey)
            sourceHits[sourceId, default: []].insert("p:" + profile.pubkey)
        }
        progress[sourceId]?.setResults(sourceHits[sourceId]?.count ?? 0)
    }

    // MARK: NIP-50 subscriptions

    private func openNIP50(sourceId: String, url: URL, verify: Bool, filters: [[String: Any]]) {
        let index = clients.count
        let client = WebSocketClient()
        client.isTemporary = true
        clients.append(client)

        var subIds: [String] = []
        for _ in filters {
            let subId = "gsearch-\(UUID().uuidString.prefix(8))"
            subIds.append(subId)
            openSubs[subId] = Subscription(sourceId: sourceId, clientIndex: index, verify: verify)
        }
        clientSubIds.append(subIds)
        progress[sourceId]?.addPending(filters.count)

        let reqs: [String] = zip(subIds, filters).compactMap { subId, filter in
            let req = ["REQ", subId, filter] as [Any]
            guard let data = try? JSONSerialization.data(withJSONObject: req) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        var sent = false
        client.messageSubject
            .receive(on: queue)
            .sink { [weak self] message in self?.handle(message: message) }
            .store(in: &cancellables)

        client.$connectionState
            .receive(on: queue)
            .sink { [weak self, weak client] state in
                guard let self = self, let client = client, !self.finished else { return }
                switch state {
                case .connected:
                    guard !sent else { return }
                    sent = true
                    for req in reqs { client.send(text: req) }
                case .error:
                    self.failClient(index, reason: sent ? "connection lost" : "could not connect")
                case .disconnected:
                    // `.disconnected` is also the initial value, published
                    // before connect(url:) runs — only a drop after the REQs
                    // went out is a failure.
                    if sent { self.failClient(index, reason: "connection lost") }
                case .connecting:
                    break
                }
            }
            .store(in: &cancellables)

        client.connect(url: url)
    }

    private func handle(message: String) {
        guard !finished,
              let data = message.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
              arr.count >= 2,
              let type = arr[0] as? String,
              let subId = arr[1] as? String,
              let sub = openSubs[subId] else { return }

        switch type {
        case "EVENT":
            guard arr.count >= 3, let ev = arr[2] as? [String: Any] else { return }
            ingest(event: ev, sub: sub)
        case "EOSE":
            openSubs[subId] = nil
            progress[sub.sourceId]?.eose()
            sendClose(subId, clientIndex: sub.clientIndex)
            closeClientIfIdle(sub.clientIndex)
        case "CLOSED":
            openSubs[subId] = nil
            let reason = (arr.count >= 3 ? arr[2] as? String : nil) ?? ""
            progress[sub.sourceId]?.closed(reason: Self.shortReason(reason))
            closeClientIfIdle(sub.clientIndex)
        default:
            return
        }
        refreshStatus(sub.sourceId)
        publishSoon()
        checkFinished()
    }

    private func ingest(event ev: [String: Any], sub: Subscription) {
        guard let id = ev["id"] as? String,
              let pubkey = ev["pubkey"] as? String,
              let kind = (ev["kind"] as? NSNumber)?.intValue,
              let content = ev["content"] as? String else { return }
        let createdAt = (ev["created_at"] as? NSNumber)?.int64Value ?? 0
        let tags = (ev["tags"] as? [[String]]) ?? []
        let matcher = sub.verify ? ownStoreMatcher : nil

        var counted = false
        if kind == 1 {
            if matcher.map({ $0.matchesNote(content: content) }) ?? true {
                let note = FeedNote(id: id, pubkey: pubkey, content: content,
                                    createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
                                    tags: tags, kind: kind)
                merge.add(note: note, id: id)
                counted = sourceHits[sub.sourceId, default: []].insert(id).inserted
            }
        } else if kind == 0, let profile = Self.parseProfile(pubkey: pubkey, content: content) {
            let matches = matcher.map {
                $0.matchesProfile(displayName: profile.displayName, name: profile.name,
                                  about: profile.about, nip05: profile.nip05, pubkey: pubkey)
            } ?? true
            if matches {
                merge.add(profile: profile, pubkey: pubkey)
                counted = sourceHits[sub.sourceId, default: []].insert("p:" + pubkey).inserted
            }
        }
        progress[sub.sourceId]?.event(counted: counted)
        refreshStatus(sub.sourceId)
        publishSoon()
    }

    static func parseProfile(pubkey: String, content: String) -> FeedProfile? {
        guard let metadata = try? JSONSerialization.jsonObject(
            with: content.data(using: .utf8) ?? Data()) as? [String: Any] else { return nil }
        var profile = FeedProfile(pubkey: pubkey)
        profile.name = metadata["name"] as? String
        profile.displayName = metadata["display_name"] as? String
        profile.pictureURL = (metadata["picture"] as? String).flatMap { URL(string: $0) }
        profile.nip05 = metadata["nip05"] as? String
        profile.about = metadata["about"] as? String
        profile.lud16 = metadata["lud16"] as? String
        profile.lud06 = metadata["lud06"] as? String
        profile.website = metadata["website"] as? String
        return profile
    }

    /// CLOSED reasons can be long ("error: we support only kind:0 search
    /// queries"); a chip has room for a few words.
    private static func shortReason(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "closed" }
        return trimmed.count > 60 ? String(trimmed.prefix(57)) + "..." : trimmed
    }

    private func sendClose(_ subId: String, clientIndex: Int) {
        guard clients.indices.contains(clientIndex) else { return }
        let msg = ["CLOSE", subId] as [Any]
        if let data = try? JSONSerialization.data(withJSONObject: msg),
           let str = String(data: data, encoding: .utf8) {
            clients[clientIndex].send(text: str)
        }
    }

    private func closeClientIfIdle(_ index: Int) {
        guard clientSubIds.indices.contains(index),
              clientSubIds[index].allSatisfy({ openSubs[$0] == nil }) else { return }
        clients[index].disconnect()
    }

    /// A socket failed: everything still open on it is over.
    private func failClient(_ index: Int, reason: String) {
        guard clientSubIds.indices.contains(index) else { return }
        let open = clientSubIds[index].filter { openSubs[$0] != nil }
        guard let first = open.first, let sourceId = openSubs[first]?.sourceId else { return }
        for subId in open { openSubs[subId] = nil }
        progress[sourceId]?.failed(reason: reason, openReqs: open.count)
        clients[index].disconnect()
        refreshStatus(sourceId)
        publishSoon()
        checkFinished()
    }

    // MARK: Status + completion

    private func refreshStatus(_ sourceId: String) {
        guard let p = progress[sourceId] else { return }
        statuses[sourceId]?.state = p.state
        statuses[sourceId]?.count = p.results
    }

    private func checkFinished() {
        guard started, !finished else { return }
        guard progress.values.allSatisfy({ $0.isDone }) else { return }
        finish()
    }

    private func hitHardCap() {
        guard started, !finished else { return }
        for id in sourceOrder {
            progress[id]?.timeout()
            refreshStatus(id)
        }
        finish()
    }

    private func finish() {
        finished = true
        teardown()
        publishNow()
    }

    private func teardown() {
        infoTask?.cancel()
        infoTask = nil
        for session in localSessions { session.cancel() }
        localSessions.removeAll()
        for client in clients { client.disconnect() }
        clients.removeAll()
        clientSubIds.removeAll()
        openSubs.removeAll()
        cancellables.removeAll()
    }

    // MARK: Publishing

    private func publishSoon() {
        guard !publishScheduled, !finished else { return }
        publishScheduled = true
        queue.asyncAfter(deadline: .now() + Self.publishInterval) { [weak self] in
            guard let self = self else { return }
            self.publishScheduled = false
            guard !self.finished else { return }
            self.publishNow()
        }
    }

    private func publishNow() {
        guard !isCancelled else { return }
        let own = request.own, follows = request.follows
        let notes = GlobalSearchRanking.rankNotes(Array(merge.notes.values),
                                                  own: own, follows: follows,
                                                  pubkey: { $0.pubkey },
                                                  createdAt: { $0.createdAt },
                                                  id: { $0.id })
        let profileOrder = GlobalSearchRanking.rankProfiles(merge.profileOrder, own: own, follows: follows)
        var snapshot = GlobalSearchSnapshot()
        snapshot.notes = Array(notes.prefix(Self.maxNotes))
        snapshot.profiles = profileOrder.compactMap { merge.profiles[$0] }
        snapshot.sources = sourceOrder.compactMap { statuses[$0] }
        snapshot.isFinished = finished

        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isCancelled else { return }
            self.onUpdate(snapshot)
        }
    }
}
