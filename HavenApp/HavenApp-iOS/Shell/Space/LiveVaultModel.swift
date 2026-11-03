import SwiftUI
import Combine

/// The Live Vault panel's lines: the Vault list's lines in fixed rows that
/// never jump (`LiveVault`). Kept by `SpaceColumn`, so the folded column and
/// a collapsed panel still know how many are new.
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

    private var nostrService: NostrService { .shared }
    private var configService: ConfigService { .shared }

    init() {
        nostrService.eventUpdateSubject
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
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
        readSeen()
        rebuild()
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
        Task.detached(priority: .utility) {
            let built = VaultActivity.build(
                events: events.filter { $0.pubkey == owner || !mutes.hides(id: $0.id, content: $0.content, tags: $0.tags) }.map {
                    VaultActivity.Event(id: $0.id, pubkey: $0.pubkey, kind: $0.kind, createdAt: $0.created_at,
                                        content: $0.content, tags: $0.tags, images: $0.mediaURLs.filter(\.isImage))
                },
                owner: owner,
                noteKinds: Set(NostrService.relayTabNoteKinds),
                isBlocked: {
                    blacklist.contains($0) || NotificationPolicy.hidesOwnAccountTag(
                        author: $0, recipient: owner, accounts: ownAccounts, notify: notifyOwn)
                },
                isOutside: { ContentFilter.isOutside(author: $0, owner: owner, whitelist: whitelist, trusted: trusted) }
            )
            let shown = Array(built.lazy.filter { !(zapsOnly && $0.kind == .reaction) }.prefix(LiveVault.maxRows * 3))
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
            }
        }
    }
}
