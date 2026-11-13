import Foundation
import Combine

/// Find emoji sets on the Emoji page (RESEARCH/NV_CUSTOM_EMOJI_PLAN.md §4.2):
/// other people's 30030 sets, by people you follow first, then everyone's from
/// the last month. Reads only; Add / Remove go through
/// `EmojiVaultStore.setListed`, which rewrites the 10030. Rules in
/// `Models/EmojiSetBrowse.swift`. Android `service/emoji/EmojiSetBrowser.kt`.
@MainActor
final class EmojiSetBrowser: ObservableObject {
    static let shared = EmojiSetBrowser()

    @Published private(set) var found: [EmojiSetBrowse.Found] = []
    @Published private(set) var loading = false
    /// Set once a browse has answered (an empty answer included).
    @Published private(set) var asked = false

    /// The account the results are for; another account's are never shown.
    private var owner = ""
    private var generation = 0
    private var lastBrowse = Date.distantPast
    /// A browse opens a socket per relay: reopening the page within this
    /// keeps the last answer.
    static let reuseFor: TimeInterval = 5 * 60
    private static let maxRelays = 8

    /// Reads again when the last answer is older than `reuseFor`, or for another account.
    func browse(force: Bool = false) {
        let nostr = NostrService.shared
        let me = nostr.activeHexPubkey
        guard !me.isEmpty else { return }
        if me != owner {
            owner = me
            found = []
            asked = false
            lastBrowse = .distantPast
        }
        guard force || !loading, force || Date().timeIntervalSince(lastBrowse) >= Self.reuseFor else { return }
        lastBrowse = Date()
        generation &+= 1
        let ticket = generation
        loading = true
        let followList = FeedService.shared.followedPubkeys
        let config = ConfigService.shared.config
        var relays: [String] = []
        for r in config.readRelays + config.writeRelays + MuteListStore.extraRelays where !relays.contains(r) && r.hasPrefix("wss://") {
            relays.append(r)
        }
        relays = Array(relays.prefix(Self.maxRelays))
        let filters = EmojiSetBrowse.filters(follows: followList)
        Task { [weak self] in
            let events = await withTaskGroup(of: [NostrEvent].self) { group in
                for filter in filters {
                    group.addTask { await nostr.fetchEvents(filter: filter, from: relays) }
                }
                var all: [NostrEvent] = []
                for await batch in group { all += batch }
                return all
            }
            guard let self, self.generation == ticket, nostr.activeHexPubkey == me else { return }
            let candidates = events.map {
                EmojiSetBrowse.Candidate(id: $0.id, pubkey: $0.pubkey, createdAt: Int64($0.created_at), kind: $0.kind, tags: $0.tags)
            }
            self.found = EmojiSetBrowse.list(candidates, follows: Set(followList),
                                             blocked: ConfigService.shared.activeAccountBlockedHexPubkeys)
            self.loading = false
            self.asked = true
        }
    }

    /// Someone blocked since the last answer leaves at once.
    func dropBlocked() {
        let blocked = ConfigService.shared.activeAccountBlockedHexPubkeys
        if found.contains(where: { blocked.contains($0.author) }) {
            found.removeAll { blocked.contains($0.author) }
        }
    }
}
