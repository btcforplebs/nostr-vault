import SwiftUI
import Combine

/// The Live Vault panel's lines: the Vault list's lines in fixed rows that
/// never jump (`LiveVault`). Kept by `SpaceColumn`, so the folded column and
/// a collapsed panel still know how many are new.
///
/// Logen 2026-11-04 (RESEARCH/NV_LIVE_VAULT_LOAD_ORDER.md): it showed only
/// zaps at first, the rest late or never. Now it rebuilds on a throttle, not
/// a debounce that every profile flush restarted; it has the new followers,
/// as the Vault tab does; it rebuilds when your web of trust changes; and it
/// fetches the notes that likes, reposts and zaps point at when they aren't
/// in memory (`VaultActivity.missingTargets`).
@MainActor
final class LiveVaultModel: ObservableObject {
    @Published private(set) var lines: [VaultActivity] = []
    @Published private(set) var shot: LiveVault.Snapshot?
    /// The Vault list's seen mark (unix seconds); newer lines are unread.
    @Published private(set) var seenAt: Int64 = 0
    /// The row at the top of the list's view, kept while lines come in.
    @Published var topId: String?

    private var owner = ""
    private var buildGen = 0
    private var cancellables = Set<AnyCancellable>()
    /// New followers from the relay's ledger, as the Vault tab passes them.
    private var follows: [(pubkey: String, at: Int64)] = []
    private var followsTask: Task<Void, Never>?

    private var nostrService: NostrService { .shared }
    private var configService: ConfigService { .shared }

    init() {
        // A throttle, not a debounce: events and profile flushes (which each
        // rebuild's own profile fetch sets off) arrive faster than once a
        // second while the vault fills, and a debounce restarted on every
        // one, so the lines waited for a quiet second that didn't come.
        nostrService.eventUpdateSubject
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)
        // The outside filter reads your web: rebuild when it arrives or changes.
        FeedService.shared.$wotPubkeys
            .map(\.count)
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)
        AccountUnreadStore.shared.$state
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.readSeen() }
            .store(in: &cancellables)
    }

    var rows: [VaultActivity] {
        guard let shot else { return Array(lines.prefix(LiveVault.maxRows)) }
        return LiveVault.split(lines, shot).rows
    }

    var unreadCount: Int { seenAt > 0 ? lines.filter { $0.createdAt > seenAt }.count : 0 }

    func attach(_ hex: String) {
        guard hex != owner else { return }
        owner = hex
        shot = nil
        lines = []
        topId = nil
        follows = []
        readSeen()
        rebuild()
        watchFollowers(hex)
    }

    /// Reads the follower ledger now and every minute, as the Vault tab does
    /// while it is on screen (`VaultView.pollFollowers`).
    private func watchFollowers(_ hex: String) {
        followsTask?.cancel()
        followsTask = Task { [weak self] in
            while !Task.isCancelled {
                let snapshot = await Task.detached(priority: .utility) { FollowerSnapshot.load(owner: hex) }.value
                guard let self, !Task.isCancelled, self.owner == hex else { return }
                let news = snapshot?.current.filter(\.isNews).map { (pubkey: $0.pubkey, at: $0.followedAt) } ?? []
                if news.map(\.pubkey) != self.follows.map(\.pubkey) {
                    self.follows = news
                    self.rebuild()
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// The Vault tab's view starts the fetch for these lines, and a tab is
    /// only built once it is opened. Until then the column asks for them
    /// itself, the same way, so it isn't empty after launch. Nothing is
    /// reset: once events are in, the Vault tab's own refresh takes over.
    func startFetchIfIdle() {
        guard nostrService.events.isEmpty else { return }
        let (urls, authors) = VaultView.activitySources(configService)
        guard !urls.isEmpty else { return }
        nostrService.fetchNotes(from: urls, since: nil, authors: authors)
    }

    private func readSeen() {
        seenAt = Int64(UserDefaults.standard.double(forKey: AccountUnread.vaultSeenKey(owner)))
    }

    /// What it's about opens on the left, through the path a tapped
    /// notification takes: the Feed tab's note view. A follow has no post,
    /// so it opens the Vault's followers.
    func open(_ line: VaultActivity) {
        guard let id = line.openId else {
            NotificationCenter.default.post(name: .havenOpenRelayFollowers, object: nil)
            return
        }
        if let event = nostrService.events.first(where: { $0.id == id }) {
            NotificationOpen.pending = .note(FeedNote(id: event.id, pubkey: event.pubkey, content: event.content,
                                                      createdAt: event.createdAtDate, tags: event.tags, kind: event.kind))
        } else {
            NotificationOpen.pending = .id(id)
        }
        NotificationCenter.default.post(name: .havenOpenFeed, object: nil)
        NotificationCenter.default.post(name: .havenOpenNotificationNote, object: nil)
    }

    /// The Vault list's lines, built as the Vault tab builds them (same
    /// mutes, blocks and outside filter), off the main thread.
    func rebuild() {
        let owner = self.owner
        guard !owner.isEmpty else { return }
        buildGen &+= 1
        let gen = buildGen
        let events = nostrService.events
        let mutes = MuteListStore.shared.active
        let blacklist = configService.activeAccountBlockedHexPubkeys
        let whitelist = configService.whitelistedHexPubkeys
        let ownAccounts = configService.allAccountHexes
        let notifyOwn = configService.config.notifyOwnAccountTags
        let trusted = FeedService.shared.relayTabTrustedPubkeys()
        let zapsOnly = configService.config.zapsOnlyMode
        let follows = self.follows
        Task.detached(priority: .utility) {
            let built = VaultActivity.build(
                events: events.filter { $0.pubkey == owner || !mutes.hides(id: $0.id, content: $0.content, tags: $0.tags) }.map {
                    VaultActivity.Event(id: $0.id, pubkey: $0.pubkey, kind: $0.kind, createdAt: $0.created_at,
                                        content: $0.content, tags: $0.tags, images: $0.mediaURLs.filter(\.isImage))
                },
                owner: owner,
                noteKinds: Set(NostrService.relayTabNoteKinds),
                follows: follows,
                isBlocked: {
                    blacklist.contains($0) || NotificationPolicy.hidesOwnAccountTag(
                        author: $0, recipient: owner, accounts: ownAccounts, notify: notifyOwn)
                },
                isOutside: { ContentFilter.isOutside(author: $0, owner: owner, whitelist: whitelist, trusted: trusted) }
            )
            let shown = Array(built.lazy.filter { !(zapsOnly && $0.kind == .reaction) }.prefix(LiveVault.maxRows * 3))
            let have = Set(events.map(\.id))
            await MainActor.run { [weak self] in
                guard let self, gen == self.buildGen else { return }
                // At the top (or not scrolled yet), the new lines show;
                // lower down, the row being read stays where it is.
                let atTop = self.topId == nil || self.topId == self.rows.first?.id
                if self.lines != shown { self.lines = shown }
                if !shown.isEmpty {
                    let next = LiveVault.place(shown, self.shot)
                    if next != self.shot { self.shot = next }
                }
                if atTop, let first = self.rows.first?.id, first != self.topId { self.topId = first }
                self.nostrService.fetchMissingProfiles(for: Array(Set(shown.prefix(LiveVault.maxRows).flatMap { $0.actors.prefix(2) })))
                ActivityTargetFetcher.shared.fetch(Array(shown.prefix(LiveVault.maxRows)), have: have)
            }
        }
    }
}
