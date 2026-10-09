import Foundation

/// The votes on each poll seen this session, fetched once per poll and shared
/// by its feed card and its note detail, so scrolling back to a poll shows
/// its count at once instead of asking every relay again.
@MainActor
final class PollStore {
    static let shared = PollStore()

    private var models: [String: PollModel] = [:]

    func model(for poll: NIP88Poll.Poll) -> PollModel {
        if let model = models[poll.id] { return model }
        let model = PollModel(poll: poll)
        models[poll.id] = model
        return model
    }
}

/// One poll's votes: what the relays said, plus the vote sent from here
/// until a relay echoes it back.
@MainActor
final class PollModel: ObservableObject {
    let poll: NIP88Poll.Poll
    @Published private(set) var tally = PollTally()
    @Published private(set) var isLoading = false
    @Published private(set) var isSending = false
    @Published var sendError: String?

    private var events: [String: [String: Any]] = [:]
    private var lastLoad: Date?
    /// A card coming back on screen asks again only after this long.
    private static let reloadAfter: TimeInterval = 30

    init(poll: NIP88Poll.Poll) {
        self.poll = poll
    }

    /// The relays a poll's votes are read from and sent to: its own, this
    /// device's, the feed's and the author's outbox.
    private var relays: [String] {
        let config = ConfigService.shared.config
        var fallback = [config.nostrURL]
        fallback += config.readRelays
        return NIP88Poll.relays(poll: poll, fallback: fallback,
                                outbox: NostrService.shared.outboxRelays[poll.pubkey] ?? [])
    }

    func load(force: Bool = false) async {
        if !force, let lastLoad, Date().timeIntervalSince(lastLoad) < Self.reloadAfter { return }
        lastLoad = Date()
        isLoading = true
        // `query` returns only signature-checked events.
        let found = await ZapHistoryService.query(
            filters: NIP88Poll.responseFilters(pollId: poll.id),
            relays: relays.compactMap { URL(string: $0) },
            onProgress: { [weak self] partial in self?.merge(partial) })
        merge(found)
        isLoading = false
    }

    private func merge(_ found: [[String: Any]]) {
        for event in found {
            if let id = event["id"] as? String { events[id] = event }
        }
        let next = NIP88Poll.tally(Array(events.values), poll: poll)
        if next != tally { tally = next }
        let missing = next.voters.filter { NostrService.shared.profiles[$0] == nil }
        if !missing.isEmpty { NostrService.shared.fetchMissingProfiles(for: Array(missing)) }
    }

    /// Signs and sends a vote, and counts it straight away.
    func vote(_ optionIds: [String]) {
        guard !isSending, !optionIds.isEmpty, !poll.isClosed() else { return }
        isSending = true
        sendError = nil
        let pollRelays = poll.relays.filter(NIP88Poll.isPublicRelay)
        let tags = NIP88Poll.responseTags(poll: poll, optionIds: optionIds,
                                          relayHint: pollRelays.first ?? ConfigService.shared.config.nostrURL)
        Task {
            defer { isSending = false }
            do {
                let event = try await ModePostPublisher.publish(
                    kind: NIP88Poll.responseKind, content: "", tags: tags,
                    extraRelays: pollRelays, nostrService: NostrService.shared)
                merge([["id": event.id, "pubkey": event.pubkey, "created_at": event.created_at,
                        "kind": event.kind, "tags": event.tags, "content": event.content, "sig": event.sig]])
            } catch {
                sendError = error.localizedDescription
            }
        }
    }
}
