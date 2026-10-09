import Foundation

/// Pure contact list management logic — no Combine, no WebSocket.
/// FeedService delegates to these functions for contact list mutations
/// and validation. The WebSocket transport layer stays in FeedService.
enum ContactManager {

    /// Errors that can occur during follow/unfollow operations.
    enum FollowActionError: Error {
        case contactsNotLoaded
        /// The load finished without the real list: a timeout, an error, or
        /// relays that never answered. Publishing now would replace the
        /// user's follows with whatever is in memory, possibly nothing.
        case listUnavailable
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

    // MARK: - New Account

    /// The contact list a newly generated key starts with: the owner first,
    /// then each picked account once, in pick order.
    ///
    /// Only for a key created in this setup run. Such a key cannot have a
    /// kind 3 anywhere yet, so publishing this replaces nothing; for any other
    /// key the list has to be fetched first and changed through `prepareFollow`.
    /// Picks that fail their checksum are dropped rather than published.
    static func newAccountContactTags(ownerHex: String, pickedNpubs: [String]) -> [[String]] {
        var tags: [[String]] = [["p", ownerHex]]
        var seen: Set<String> = [ownerHex]
        for npub in pickedNpubs {
            if let hex = NpubValidation.hexPubkey(fromNpub: npub), seen.insert(hex).inserted {
                tags.append(["p", hex])
            }
        }
        return tags
    }

    /// The starter-pack npubs that setup used to write into
    /// `whitelistedNpubs` when someone tapped "Follow" on the Discover Accounts
    /// step. That list is the user's own accounts, so each pick turned up in
    /// Switch Account and "post as" and was treated by the relay as a second
    /// owner, and nobody was followed. These are the npubs as they shipped
    /// (bfca0d16 and earlier), most of them wrong people, which is exactly why
    /// they have to be listed here rather than read from the current file.
    static let starterNpubsSetupAddedAsAccounts: Set<String> = [
        "npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m", // jack
        "npub1cn4t4cd78nm900qc2hhqte5aa8c9njm6qkfzw95tszufwcwtcnsq7g3vle", // "nvk"
        "npub1az9xj85cmxv8e9j9y80lvqp97crsqdu2fpu3srwthd99qfu9qsgstam8y8", // "LynAlden"
        "npub1gdu7w6l6w65qhrdeaf6eyywepwe7v7ezqtugsrxy7hl7ypjsvxksd76nak", // "ODELL"
        "npub1s33sw46p7vpsmak6v8j4x2naxqvqgv5xpep0lmllz9lxm7qds8gs8r5n32", // "MartyBent"
        "npub1l2vyh47mk2p0qlsku7hg0vn29faehy9hy34ygaclpn66ukqp3afqutajft", // "fiatjaf"
        "npub1jlrs53pkdfjnts29kveljul2sm0actt6n8dxrrzqcersttvcuv3qdjynqn", // "jb55"
        "npub12vkcxr0luzwp8e673v29eqjhrr7p9vqq8asav85swaepclllj09sylpugg", // "miljan"
        "npub1gcxzte5zlkncx26j68ez60fzkvtkm9e0vrwdcvsjakxf9mu9qewqlfnj5z", // vitor
        "npub1wjwj5r9ytyhgg7nwmy75t8pqzn7xapg5c5k0q8q9qqk9f1vvv4qsvvxs2w", // "Snowden"
        "npub1wmr34t36fy03m8hvgl96zl3znndyzyaqhwmwdtshwmtkg03fetaqhjg240", // "saylor"
        "npub1xnf02f60r9v0e5kty33a404dm79zr7z2eepyrk5gsq3m7pwvsz2sazlpr5", // "gladstein"
        "npub1h8nk2346qezka5cpm8jjh3yl5j88pf4ly2ptu7s6uu55wcfqy0wq36rpev", // "carla"
        "npub1qny3tkh0acurzla8x3zy4nhrjz5zd8l9sy9jys09umwng00manysew95gx", // "preston"
        "npub1hu3hdctm5nkzd8gslnyedfr5ddz3z547jqcl5j88g4fame2jd08qh6h8nh", // "walker"
    ]

    /// `accounts` minus the starter-pack npubs setup added by mistake. An entry
    /// is kept if this device can sign for it (`canSign`): someone who really
    /// added one of these people as an account did so with their key.
    static func accountsWithoutStarterPackPicks(_ accounts: [String], canSign: (String) -> Bool) -> [String] {
        accounts.filter { entry in
            let npub = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            return !starterNpubsSetupAddedAsAccounts.contains(npub) || canSign(npub)
        }
    }

    // MARK: - Follow / Unfollow

    /// Validates and performs a follow operation on the tag list.
    /// Returns updated tags/pubkeys on success, or an error.
    static func prepareFollow(
        pubkey: String,
        currentPTags: [[String]],
        currentPubkeys: [String],
        hasAttemptedLoad: Bool,
        isLoading: Bool,
        listConfirmed: Bool
    ) -> Result<(pTags: [[String]], pubkeys: [String]), FollowActionError> {
        guard hasAttemptedLoad, !isLoading else { return .failure(.contactsNotLoaded) }
        guard listConfirmed else { return .failure(.listUnavailable) }
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
        isLoading: Bool,
        listConfirmed: Bool
    ) -> Result<(pTags: [[String]], pubkeys: [String]), FollowActionError> {
        guard hasAttemptedLoad, !isLoading else { return .failure(.contactsNotLoaded) }
        guard listConfirmed else { return .failure(.listUnavailable) }
        guard pubkey != activeAccountHex else { return .failure(.cannotUnfollowSelf) }
        var newPTags = currentPTags
        var newPubkeys = currentPubkeys
        newPTags.removeAll { $0.count >= 2 && $0[1] == pubkey }
        newPubkeys.removeAll { $0 == pubkey }
        return .success((newPTags, newPubkeys))
    }

    // MARK: - Safety Checks

    /// Whether the user's real follow list is known: a kind 3 came back, or
    /// every relay answered (EOSE) with none, i.e. a genuinely new account.
    /// A timeout, an error or no relays leave it false. Follow / unfollow and
    /// queued taps publish only when it is true.
    static func mayPublishFollowList(hasAttemptedLoad: Bool, isLoading: Bool, listConfirmed: Bool) -> Bool {
        hasAttemptedLoad && !isLoading && listConfirmed
    }

    /// Which relays have finished answering one follow-list request. Counts a
    /// relay once, and only for the subscription id it was sent: a relay that
    /// repeats EOSE (buggy or hostile) must not make the relay that actually
    /// holds the list look like it answered "none".
    struct EOSETally {
        private var subIds: [String: String] = [:]   // relay -> sub id sent to it
        private(set) var answered: Set<String> = []

        init() {}

        mutating func sent(subId: String, to relay: String) { subIds[relay] = subId }

        /// Records an EOSE; ignored unless it is for the sub id sent to that relay.
        mutating func eose(from relay: String, subId: String) {
            guard subIds[relay] == subId else { return }
            answered.insert(relay)
        }

        func isAnswer(from relay: String, subId: String) -> Bool { subIds[relay] == subId }
    }

    /// `listConfirmed` after one load: true when a list was found, or when no
    /// list was found but every relay answered. False on timeout / error.
    static func loadConfirmsList(foundList: Bool, relaysAsked: Int, relaysAnswered: Int) -> Bool {
        foundList || (relaysAsked > 0 && relaysAnswered >= relaysAsked)
    }

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
