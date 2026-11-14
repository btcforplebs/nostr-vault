import SwiftUI

// MARK: - Follower ledger read

extension FollowerSnapshot {
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

    /// Whether a follower of `owner` is outside that account's web: the
    /// Notes page's rule with the account's own web (each account judged by
    /// its own, like its alerts).
    func followerIsOutside(owner: String) -> (String) -> Bool {
        let trusted = FeedService.shared.trustedPubkeys(for: owner)
        let whitelist = configService.whitelistedHexPubkeys
        return { ContentFilter.isOutside(author: $0, owner: owner, whitelist: whitelist, trusted: trusted) }
    }

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
                    // Only follows from inside your web light the dot.
                    let hasNew = snapshot.news(isOutside: followerIsOutside(owner: owner)).contains { $0.followedAt > seen }
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
        guard let snapshots = shownFollowerSnapshots else { return }
        let shown = followerEntries(snapshots).prefix(300).map(\.pubkey)
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

    /// The ledgers the chip shows, with their owners: the active account's,
    /// or each picked account's (read with the other accounts' pages). Nil
    /// until one is read.
    var shownFollowerSnapshots: [(owner: String, snapshot: FollowerSnapshot)]? {
        let me = followersOwnerHex.lowercased()
        let owners = pageOwners
        guard owners != [me] else { return followerSnapshot.map { [(me, $0)] } }
        let read = owners.sorted().compactMap { owner in
            (owner == me ? followerSnapshot : otherFollowerSnapshots[owner]).map { (owner, $0) }
        }
        return read.isEmpty ? nil : read
    }

    /// Each ledger cut to the picked side of its own account's web; several
    /// merged (VaultAccountChips.mergeFollowers).
    func followerEntries(_ snapshots: [(owner: String, snapshot: FollowerSnapshot)]) -> [FollowerSnapshot.Entry] {
        let lists = snapshots.map { $0.snapshot.entries(for: followersFilter, isOutside: followerIsOutside(owner: $0.owner)) }
        guard lists.count > 1 else { return lists.first ?? [] }
        return VaultAccountChips.mergeFollowers(lists, id: \.pubkey, isNews: \.isNews,
                                                followedAt: \.followedAt, listAt: \.listAt)
    }

    @ViewBuilder
    var followersList: some View {
        if let snapshots = shownFollowerSnapshots {
            let entries = followerEntries(snapshots)
            LazyVStack(spacing: 0) {
                followersSummary(entries.count)
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

    /// The count of the list on show. Spam is left out on purpose.
    private func followersSummary(_ count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: followersFilter == .outside ? "person.crop.circle.badge.questionmark" : "person.2.fill")
                .foregroundColor(.havenPurple)
            Text(followersFilter == .outside
                 ? "\(count) outside your web"
                 : "\(count) \(count == 1 ? "follower" : "followers") in your web")
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
            Text(followersFilter == .outside ? "No followers outside your web" : "No followers in your web yet")
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
