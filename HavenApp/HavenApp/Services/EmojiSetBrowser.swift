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
    /// Your own 30030s from the vault (outbox and list history) and your
    /// relays, every version, read with each browse.
    @Published private(set) var ownVersions: [EmojiSetBrowse.Candidate] = []
    /// The sets an Add back is working on.
    @Published private(set) var restoring: Set<String> = []

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
            ownVersions = []
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
        var ownRelays = NostrService.ownListRelays(for: me)
        for r in relays + (nostr.outboxRelays[me] ?? []) where !ownRelays.contains(r) { ownRelays.append(r) }
        Task { [weak self] in
            let own = await Self.readOwn(me, relays: ownRelays, nostr: nostr)
            guard let self, self.generation == ticket, nostr.activeHexPubkey == me else { return }
            self.ownVersions = own
        }
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

    /// Every version of your own 30030s: the vault's outbox and list
    /// history (which keeps old versions once a set is replaced) and your relays.
    private static func readOwn(_ me: String, relays: [String], nostr: NostrService) async -> [EmojiSetBrowse.Candidate] {
        let filter: [String: Any] = ["kinds": [30030], "authors": [me]]
        async let outbox = VaultSocket.queryAll(path: "", filter: filter)
        async let history = VaultSocket.queryAll(path: "/lists", filter: filter)
        async let net = nostr.fetchEvents(filter: filter.merging(["limit": 500]) { a, _ in a }, from: relays)
        let all = (await outbox ?? []) + (await history ?? []) + (await net)
        return all.map {
            EmojiSetBrowse.Candidate(id: $0.id, pubkey: $0.pubkey, createdAt: Int64($0.created_at), kind: $0.kind,
                                     tags: $0.tags, content: $0.content)
        }
    }

    /// Add back one of your old sets: when its newest copy was wiped, the
    /// kept version is signed again first (list restore, the same checks as
    /// List backups: newest fetched again, kept in the vault first), then it
    /// goes into your emoji list. Nil when done, else what to tell the person.
    func addBack(_ old: EmojiSetBrowse.OldSet) async -> String? {
        let address = old.found.set.address
        guard !restoring.contains(address) else { return nil }
        restoring.insert(address)
        defer { restoring.remove(address) }
        if old.needsRestore {
            guard let kept = ownVersions.first(where: { $0.id == old.versionID }) else { return "That version isn't here anymore." }
            let version = ListVersion(id: kept.id, pubkey: kept.pubkey, kind: kept.kind, createdAt: kept.createdAt,
                                      tags: kept.tags, content: kept.content)
            let error = await ListBackupService.shared.restoreWithPreview(version)
            if let error { return error }
        }
        if !old.listed {
            guard await EmojiVaultStore.shared.setListed(address, on: true) else { return "Your emoji list couldn't be updated." }
        }
        browse(force: true)
        return nil
    }

    /// Someone blocked since the last answer leaves at once.
    func dropBlocked() {
        let blocked = ConfigService.shared.activeAccountBlockedHexPubkeys
        if found.contains(where: { blocked.contains($0.author) }) {
            found.removeAll { blocked.contains($0.author) }
        }
    }
}
