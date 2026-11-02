import SwiftUI
import Combine

// MARK: - Your space (iPad landscape)

/// The iPad's right-hand column in landscape, after the web's desktop
/// "Your space": Live Vault, the Vault list's lines in fixed rows that never
/// jump. Lines that arrive after it was drawn wait behind an "N new" pill;
/// tapping the pill draws them and marks the Vault seen, as a look at the
/// Vault list does. A row opens what it's about on the left. Folds to a
/// thin strip with the unread count; the choice is kept per account.
struct LiveVaultColumn: View {
    @EnvironmentObject var configService: ConfigService
    @ObservedObject private var nostrService = NostrService.shared
    @ObservedObject private var unreadStore = AccountUnreadStore.shared

    @State private var lines: [VaultActivity] = []
    @State private var shot: LiveVault.Snapshot?
    /// The Vault list's seen mark (unix seconds); newer lines are unread.
    @State private var seenAt: Int64 = 0
    @State private var folded = false
    @State private var buildGen = 0

    private var owner: String { configService.activeAccountHexPubkey.lowercased() }

    private var split: (rows: [VaultActivity], held: [VaultActivity]) {
        guard let shot else { return (Array(lines.prefix(LiveVault.maxRows)), []) }
        return LiveVault.split(lines, shot)
    }

    private var unreadCount: Int { seenAt > 0 ? lines.filter { $0.createdAt > seenAt }.count : 0 }

    var body: some View {
        let (rows, held) = split
        let pill = LiveVault.pillCount(unread: unreadCount, held: held.count)
        Group {
            if folded {
                foldedStrip(count: unreadCount)
            } else {
                VStack(spacing: 0) {
                    header(rows: rows, pill: pill)
                    Divider()
                    list(rows)
                }
                .frame(width: LiveVaultLayout.openWidth)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.platformWindowBackground)
        .onChange(of: owner, initial: true) { _, hex in
            folded = UserDefaults.standard.bool(forKey: LiveVault.foldedKey(hex))
            shot = nil
            lines = []
            readSeen()
            rebuild()
        }
        .onReceive(nostrService.eventUpdateSubject.debounce(for: .seconds(1), scheduler: RunLoop.main)) { _ in
            rebuild()
        }
        .onReceive(unreadStore.$state.removeDuplicates()) { _ in readSeen() }
    }

    // MARK: Pieces

    private func header(rows: [VaultActivity], pill: Int) -> some View {
        let (faces, more) = LiveVault.faces(unreadCount > 0 ? Array(lines.prefix(unreadCount)) : rows)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Live Vault")
                    .font(.appSystem(size: 17, weight: .bold))
                Spacer()
                Button { setFolded(true) } label: {
                    Image(systemName: "sidebar.right")
                        .font(.appSystem(size: 16, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .accessibilityLabel("Fold Your space")
            }
            HStack(spacing: 8) {
                HStack(spacing: -8) {
                    ForEach(faces, id: \.self) { pk in
                        AvatarView(url: nostrService.profiles[pk]?.pictureURL, pubkey: pk, size: 28)
                            .overlay(Circle().stroke(Color.platformWindowBackground, lineWidth: 2))
                    }
                }
                .accessibilityHidden(true)
                if more > 0 {
                    Text("+\(more)")
                        .font(.appSystem(size: 12, weight: .bold))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if pill > 0 {
                    Button(action: showNew) {
                        Text("\(pill) new")
                            .font(.appSystem(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.havenPurple))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func list(_ rows: [VaultActivity]) -> some View {
        if rows.isEmpty {
            Text(nostrService.isFetching ? "Loading your vault..." : "Replies, likes, zaps and new followers land here")
                .font(.appSystem(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { line in
                        Button { open(line) } label: {
                            VaultActivityRow(line: line, isUnread: seenAt > 0 && line.createdAt > seenAt, compact: true)
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 12)
                    }
                }
            }
        }
    }

    private func foldedStrip(count: Int) -> some View {
        Button { setFolded(false) } label: {
            VStack(spacing: 10) {
                Image(systemName: "sidebar.left")
                    .font(.appSystem(size: 16, weight: .semibold))
                    .foregroundColor(.secondary)
                Image(systemName: VaultMode.activity.symbol)
                    .font(.appSystem(size: 18))
                    .foregroundColor(.havenPurple)
                if let badge = AccountUnread.badge(count) {
                    Text(badge)
                        .font(.appSystem(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.havenPurple))
                }
                Spacer()
            }
            .padding(.top, 16)
            .frame(width: LiveVaultLayout.foldedWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count > 0 ? "Open Your space, \(count) new" : "Open Your space")
    }

    // MARK: Actions

    private func setFolded(_ value: Bool) {
        folded = value
        UserDefaults.standard.set(value, forKey: LiveVault.foldedKey(owner))
    }

    /// The pill: draw the waiting lines and mark the Vault seen.
    private func showNew() {
        shot = LiveVault.snapshot(lines)
        let now = Date().timeIntervalSince1970
        AccountUnreadStore.shared.markVaultSeen(hex: owner, at: now)
        seenAt = Int64(now)
    }

    private func readSeen() {
        seenAt = Int64(UserDefaults.standard.double(forKey: AccountUnread.vaultSeenKey(owner)))
    }

    /// What it's about opens on the left, through the path a tapped
    /// notification takes: the Feed tab's note view. A follow has no post,
    /// so it opens the Vault's followers.
    private func open(_ line: VaultActivity) {
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
    private func rebuild() {
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
            await MainActor.run {
                guard gen == buildGen else { return }
                if lines != shown { lines = shown }
                if shot == nil, !shown.isEmpty { shot = LiveVault.snapshot(shown) }
                nostrService.fetchMissingProfiles(for: Array(Set(shown.prefix(LiveVault.maxRows).flatMap { $0.actors.prefix(2) })))
            }
        }
    }
}
