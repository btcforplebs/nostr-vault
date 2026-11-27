import Foundation

/// The Followers number counts only followers inside your web, on your own
/// profile and on everyone else's (Logen 11-27). The one gate decides who is
/// inside (`WebGate.judge` on the follower), so the number, the list it
/// opens and the Vault agree.
///
/// - Your own: your relay's ledger, which is complete, less everyone outside.
/// - Anyone else's: the followers loaded so far that are inside, plus your
///   follows that follow them (the relay's links file, no fetch needed).
///   Nobody can list everyone's contact lists, so it shows "+" until the
///   follower list has been read to the end.
extension ProfileFeedLoader {
    /// Followers of this profile inside your web that are known now.
    var insideFollowers: Set<String> {
        let gate = feedService.feedGate
        var out = Set<String>()
        for key in followerPubkeys where WebGate.isInside(key, in: gate) { out.insert(key) }
        if !usesOwnLedger {
            for key in followsWhoFollow where WebGate.isInside(key, in: gate) { out.insert(key) }
        }
        return out
    }

    /// Your follows that follow this profile, from the links file.
    var followsWhoFollow: Set<String> {
        feedService.trustedWebMemo.followers(of: pubkey, among: Set(feedService.followedPubkeys))
    }

    /// The header's Followers number: "—" until something is known.
    var followersShownText: String {
        if usesOwnLedger {
            if let ownLedgerCount { return ProfileFormat.shortInt(ownLedgerCount) }
            // Your relay is stopped or still opening: the relays' sample.
            let sampled = insideFollowers.count
            return sampled == 0 ? "—" : ProfileFormat.shortInt(sampled) + "+"
        }
        let count = insideFollowers.count
        if followersExhausted { return ProfileFormat.shortInt(count) }
        return count == 0 && followerSeenAt.isEmpty && followsWhoFollow.isEmpty
            ? "—" : ProfileFormat.shortInt(count) + "+"
    }

    /// Your own ledger, less followers outside your web. Runs off main.
    static func insideLedgerCount(owner: String, gate: WebGate.Web) async -> Int? {
        await Task.detached(priority: .userInitiated) {
            FollowerSnapshot.load(owner: owner)?.current.filter { WebGate.isInside($0.pubkey, in: gate) }.count
        }.value
    }
}
