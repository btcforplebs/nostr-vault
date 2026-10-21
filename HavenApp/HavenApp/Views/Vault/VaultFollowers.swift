import SwiftUI

// MARK: - Follower ledger model

/// One owner's followers from the relay's follower ledger (`GetFollowersC`).
/// The relay already sorts them newest follow first and puts each in a tier.
struct FollowerSnapshot: Decodable {
    struct Counts: Decodable {
        let trusted: Int
        let others: Int
        let spam: Int
        let unfollowed: Int
    }

    struct Entry: Decodable, Identifiable {
        let pubkey: String
        let tier: String
        let following: Bool
        /// Followed before the ledger started: not news.
        let existing: Bool
        let followedAt: Int64
        /// Follow starts we saw; more than one means they left and came back.
        let follows: Int
        /// Their latest list time. For a follow that predates the ledger it is
        /// the only "when" there is, so it orders those.
        let listAt: Int64

        var id: String { pubkey }
        var isSpam: Bool { tier == "spam" }
        var isReturning: Bool { follows > 1 }
        /// A follow we watched happen: a first follow since the ledger began,
        /// or a comeback. A refollow bot republishing its list is neither.
        var isNews: Bool { following && !isSpam && (!existing || isReturning) }
        var followedDate: Date { Date(timeIntervalSince1970: TimeInterval(followedAt)) }

        enum CodingKeys: String, CodingKey {
            case pubkey, tier, following, existing, follows
            case followedAt = "followed_at"
            case listAt = "list_at"
        }
    }

    let counts: Counts
    let followers: [Entry]

    /// Current followers, spam left out, newest first: follows we watched
    /// happen (the relay already sorts them newest first), then everyone who
    /// followed before tracking began, newest list first.
    var current: [Entry] {
        let current = followers.filter { $0.following && !$0.isSpam }
        let watched = current.filter(\.isNews)
        let earlier = current.filter { !$0.isNews }.sorted { $0.listAt > $1.listAt }
        return watched + earlier
    }

    func entries(for filter: FollowersFilter) -> [Entry] {
        switch filter {
        case .new: return Array(current.prefix(Self.newLimit))
        case .all: return current
        }
    }

    static let newLimit = 100

    /// Reads the ledger from the embedded relay. Nil while the relay is
    /// stopped or the ledger hasn't opened yet.
    static func load(owner: String) -> FollowerSnapshot? {
        guard !owner.isEmpty, let ptr = owner.withCString({ GetFollowersC(UnsafeMutablePointer(mutating: $0)) }) else { return nil }
        defer { free(ptr) }
        guard let data = String(cString: ptr).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(FollowerSnapshot.self, from: data)
    }
}

// MARK: - Followers mode

extension VaultView {

    /// The account whose followers the Relay tab shows: the active account,
    /// or the owner when none is picked.
    var followersOwnerHex: String {
        let npub = configService.config.activeAccountNpub
        if !npub.isEmpty, let hex = Bech32.decode(npub)?.hexString { return hex }
        return nostrService.ownerHexPubkey
    }

    private var followersSeenKey: String { "followersSeenAt.\(followersOwnerHex)" }

    /// Reloads the ledger, refreshes the red dot and asks for the profiles
    /// the list is about to show.
    func refreshFollowers() {
        let owner = followersOwnerHex
        Task.detached(priority: .utility) {
            let snapshot = FollowerSnapshot.load(owner: owner)
            await MainActor.run {
                guard owner == followersOwnerHex, let snapshot else { return }
                followerSnapshot = snapshot
                if viewMode == .activity { scheduleUpdateDisplayData() }
                if watchedMode == .followers || watchedMode == .activity {
                    markFollowersSeen()
                } else {
                    let seen = Int64(UserDefaults.standard.double(forKey: followersSeenKey))
                    let hasNew = snapshot.followers.contains { $0.isNews && $0.followedAt > seen }
                    if hasNew != hasNewFollowers {
                        withAnimation(Motion.fade) { hasNewFollowers = hasNew }
                    }
                }
                fetchFollowerProfiles()
            }
        }
    }

    func markFollowersSeen() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: followersSeenKey)
        if hasNewFollowers {
            withAnimation(Motion.fade) { hasNewFollowers = false }
        }
    }

    func fetchFollowerProfiles() {
        guard let followerSnapshot else { return }
        let shown = followerSnapshot.entries(for: followersFilter).prefix(300).map(\.pubkey)
        nostrService.fetchMissingProfiles(for: Array(shown))
    }

    /// Re-reads the ledger every minute while the Relay tab is on screen. A
    /// new follow reaches the relay's ledger live, so this is what makes the
    /// list and the dot "semi-realtime".
    func pollFollowers() async {
        while !Task.isCancelled {
            refreshFollowers()
            try? await Task.sleep(for: .seconds(60))
        }
    }

    @ViewBuilder
    var followersList: some View {
        if let followerSnapshot {
            let entries = followerSnapshot.entries(for: followersFilter)
            LazyVStack(spacing: 0) {
                followersSummary(followerSnapshot)
                if entries.isEmpty {
                    followersEmptyState
                } else {
                    ForEach(entries) { entry in
                        FollowerRow(
                            entry: entry,
                            profile: nostrService.profiles[entry.pubkey]
                        )
                        .onTapGesture { showingProfilePubkey = entry.pubkey }
                        Divider()
                            .background(Color(red: 0.2, green: 0.2, blue: 0.25))
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .onChange(of: followersFilter) { _, _ in fetchFollowerProfiles() }
        } else {
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Color.havenPurple)
                Text(relayManager.isRunning ? "Loading followers..." : "Followers show once the relay is running")
                    .font(.appSystem(size: 15, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
        }
    }

    /// One count. Spam is left out on purpose.
    private func followersSummary(_ snapshot: FollowerSnapshot) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "person.2.fill")
                .foregroundColor(.havenPurple)
            Text("\(snapshot.counts.trusted + snapshot.counts.others) followers")
                .font(.appSystem(size: 15, weight: .bold))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var followersEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.2")
                .font(.appSystem(size: 40, weight: .thin))
                .foregroundColor(.havenPurple)
            Text("No followers here yet")
                .font(.appSystem(size: 17, weight: .bold))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

// MARK: - Row

struct FollowerRow: View {
    let entry: FollowerSnapshot.Entry
    let profile: FeedProfile?

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(url: profile?.pictureURL, pubkey: entry.pubkey, size: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.appSystem(size: 15, weight: .semibold))
                    .lineLimit(1)
                if let nip05 = profile?.nip05, !nip05.isEmpty {
                    Text(nip05)
                        .font(.appSystem(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if entry.isNews {
                Text(entry.isReturning ? "Returning" : "New")
                    .font(.appSystem(size: 11, weight: .bold))
                    .foregroundColor(entry.isReturning ? .orange : .havenPurple)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill((entry.isReturning ? Color.orange : Color.havenPurple).opacity(0.16)))
                Text(CondensedNoteLine.relativeTime(entry.followedDate))
                    .font(.appSystem(size: 12))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var name: String {
        if let profile { return profile.bestName }
        let npub = Bech32.encode(hrp: "npub", data: Data(hexString: entry.pubkey) ?? Data()) ?? entry.pubkey
        return String(npub.prefix(16)) + "…"
    }
}
