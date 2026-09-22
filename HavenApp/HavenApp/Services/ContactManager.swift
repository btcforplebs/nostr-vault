import Foundation

/// Pure contact list management logic — no Combine, no WebSocket.
/// FeedService delegates to these functions for contact list mutations
/// and validation. The WebSocket transport layer stays in FeedService.
enum ContactManager {

    /// Errors that can occur during follow/unfollow operations.
    enum FollowActionError: Error {
        case contactsNotLoaded
        case alreadyFollowing
        case cannotUnfollowSelf
    }

    // MARK: - Contact List Parsing

    /// Parses a kind-3 contact list event's p-tags into the canonical follow set.
    /// Ensures the owner and whitelisted accounts are included.
    ///
    /// - Parameters:
    ///   - pTags: Pre-filtered "p" tags from the kind-3 event (e.g. ["p", hex, relay?, petname?]).
    ///   - ownerHex: Hex pubkey of the current account owner.
    ///   - whitelistedNpubs: Npub strings of accounts to auto-follow.
    /// - Returns: Tuple of (finalPTags, followedPubkeys, relayPTagCount) where
    ///   relayPTagCount is the count from the relay before owner/whitelist additions.
    static func parseContactList(
        pTags: [[String]],
        ownerHex: String,
        whitelistedNpubs: [String]
    ) -> (pTags: [[String]], pubkeys: [String], relayPTagCount: Int) {
        let relayCount = pTags.count
        var finalPTags = pTags
        let existingPubkeys = Set(pTags.compactMap { $0.count >= 2 ? $0[1] : nil })

        // Ensure owner is in the list
        if !existingPubkeys.contains(ownerHex) {
            finalPTags.append(["p", ownerHex])
        }

        // Auto-follow whitelisted accounts.
        //
        // Checksum-validating rather than Bech32.decode: these p-tags are
        // published in a signed kind-3 event, so a malformed npub does not fail
        // quietly here, it becomes part of the user's contact list on relays.
        // The lenient decoder returns 32 plausible bytes for a typo'd npub and
        // 3 bytes for one containing a stray "1", and both would go in as-is.
        for npub in whitelistedNpubs {
            if let hex = NpubValidation.hexPubkey(fromNpub: npub), !existingPubkeys.contains(hex) {
                finalPTags.append(["p", hex])
            }
        }

        let pubkeys = finalPTags.compactMap { $0.count >= 2 ? $0[1] : nil }
        return (finalPTags, pubkeys, relayCount)
    }

    // MARK: - Follow / Unfollow

    /// Validates and performs a follow operation on the tag list.
    /// Returns updated tags/pubkeys on success, or an error.
    static func prepareFollow(
        pubkey: String,
        currentPTags: [[String]],
        currentPubkeys: [String],
        hasAttemptedLoad: Bool,
        isLoading: Bool
    ) -> Result<(pTags: [[String]], pubkeys: [String]), FollowActionError> {
        guard hasAttemptedLoad, !isLoading else { return .failure(.contactsNotLoaded) }
        guard !currentPubkeys.contains(pubkey) else { return .failure(.alreadyFollowing) }
        var newPTags = currentPTags
        var newPubkeys = currentPubkeys
        newPTags.append(["p", pubkey])
        newPubkeys.append(pubkey)
        return .success((newPTags, newPubkeys))
    }

    /// Validates and performs an unfollow operation on the tag list.
    /// Returns updated tags/pubkeys on success, or an error.
    static func prepareUnfollow(
        pubkey: String,
        activeAccountHex: String,
        currentPTags: [[String]],
        currentPubkeys: [String],
        hasAttemptedLoad: Bool,
        isLoading: Bool
    ) -> Result<(pTags: [[String]], pubkeys: [String]), FollowActionError> {
        guard hasAttemptedLoad, !isLoading else { return .failure(.contactsNotLoaded) }
        guard pubkey != activeAccountHex else { return .failure(.cannotUnfollowSelf) }
        var newPTags = currentPTags
        var newPubkeys = currentPubkeys
        newPTags.removeAll { $0.count >= 2 && $0[1] == pubkey }
        newPubkeys.removeAll { $0 == pubkey }
        return .success((newPTags, newPubkeys))
    }

    // MARK: - Safety Checks

    /// Returns true if publishing the contact list should be BLOCKED because
    /// it would shrink drastically relative to the last relay-fetched count
    /// (prevents accidental follow-list wipes from stale data).
    static func shouldBlockPublish(currentTagCount: Int, lastFetchedCount: Int) -> Bool {
        guard lastFetchedCount > 10 else { return false }
        let ratio = Double(currentTagCount) / Double(lastFetchedCount)
        return ratio < 0.5
    }

    // MARK: - Extended Network

    /// Counts mutual follows from a single kind-3 event's tags, excluding
    /// the user's own follows. Used incrementally as events arrive from relays.
    static func countMutualFollows(
        eventTags: [[String]],
        excludeSet: Set<String>
    ) -> [String: Int] {
        var counts: [String: Int] = [:]
        for tag in eventTags {
            if tag.count >= 2, tag[0] == "p" {
                let pk = tag[1]
                if !excludeSet.contains(pk) {
                    counts[pk, default: 0] += 1
                }
            }
        }
        return counts
    }

    /// Ranks pubkeys by mutual-follow count and returns the top results.
    /// Call after all kind-3 events have been accumulated.
    ///
    /// The order is total — ties break on the pubkey — because it is truncated.
    /// Most of the second hop is followed by exactly one or two of your
    /// follows, so `maxResults` almost always cuts through the middle of a
    /// large tie group; ordering on the count alone let a dictionary's
    /// per-process iteration order decide who was inside it, and the discovery
    /// feed changed every time it was recomputed from identical data.
    static func rankExtendedNetwork(
        mutualCounts: [String: Int],
        maxResults: Int = 500
    ) -> [String] {
        let sorted = mutualCounts.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }
        return Array(sorted.prefix(maxResults).map { $0.key })
    }
}
