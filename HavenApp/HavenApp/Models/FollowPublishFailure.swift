import Foundation

/// Why `FeedService.publishContactList` put a follow or unfollow back. Each
/// exit names its own reason so the banner can say what went wrong, not just
/// "try again" (rd, 2026-11-27). Same strings as Android and web.
enum FollowPublishFailure: Equatable {
    /// The new list would drop below half of the last one (ContactManager.mayPublish).
    case wouldShrink
    /// No key here and no bunker.
    case readOnly
    /// The tap carried no list to build on.
    case noBefore
    /// The active account changed while the list was being made.
    case accountSwitched
    /// The account has no kind 10002 of its own (ListMerge.EditBase.noRelayList).
    case noRelayList
    /// Not enough relays answered the fresh lookup (ListMerge.EditBase.unknown).
    /// `ownAnswered` of the account's `own` write relays answered.
    case relaysDidNotAnswer(ownAnswered: Int, own: Int)
    /// Fewer than two of the account's own relays answered the fresh
    /// lookup, `answered` of them (ListMerge.followMajority).
    case tooFewAnswered(answered: Int)
    /// The account's relay list names one relay, and it or purplepag.es (its
    /// second answer, ListMerge.followCounted) didn't answer.
    case oneRelayList
    /// The signer returned nothing (a bunker that refused or timed out).
    case notSigned
    /// The signer signed with a key that isn't the account's.
    case wrongSigner
    /// Signed and sent, and every relay refused it.
    case refused

    /// The banner text for a follow (`follow`) or unfollow tap.
    func message(follow: Bool) -> String {
        let verb = follow ? "follow" : "unfollow"
        let lead = "Couldn't \(verb): "
        switch self {
        case .readOnly:
            return "This account is read-only. Add its key to \(verb)."
        case .noRelayList:
            return "Couldn't \(verb). " + ListMerge.noRelayListMessage
        case .relaysDidNotAnswer(let ownAnswered, let own) where ownAnswered < own:
            return lead + "only \(ownAnswered) of your \(own) relays answered, so your newest follow list can't be checked. Nothing changed. Remove dead relays in Settings › Relays, then try again."
        case .oneRelayList:
            return lead + "your relay list has only one relay, and your newest follow list needs two of your relays to answer before it can be checked. Nothing changed. Add a relay in Settings › Relays, then try again."
        case .tooFewAnswered(0):
            return lead + "none of your relays answered, so your newest follow list can't be checked. Nothing changed. Check your connection, then try again."
        case .tooFewAnswered:
            return lead + "only 1 of your relays answered, and it takes 2 of them to check your newest follow list. Nothing changed. Try again in a moment."
        case .relaysDidNotAnswer:
            return lead + "not enough relays answered, so your newest follow list can't be checked. Nothing changed. Try again in a moment."
        case .notSigned:
            return lead + "your signer didn't sign it. Nothing changed. Check your signer, then try again."
        case .wrongSigner:
            return lead + "your signer signed with a different key. Nothing changed. Check which account your signer is on."
        case .refused:
            return lead + "every relay refused it. Nothing changed. Check your relays in Settings › Relays."
        case .wouldShrink:
            return lead + "the new list would have less than half the people of your last one, so it was stopped to protect your follows. Nothing changed."
        case .accountSwitched:
            return lead + "you switched accounts before it was sent. Nothing changed."
        case .noBefore:
            return lead + "the app lost track of the list this tap was made on. Nothing changed. Try again."
        }
    }

    /// Why a lookup left the follow list `.unknown`, counting only the
    /// account's `own` relays (ListMerge.followMajority): a one-relay list
    /// whose relay or purplepag.es didn't answer, under two own answers, or
    /// not most of the ones that connected. A one-relay list where both did
    /// answer (refused by another guard) gets the general text.
    static func didNotAnswer<Event>(_ lookup: ReplaceableLookup<Event>, own: [String]) -> FollowPublishFailure {
        let oneRelay = Set(own.map(ListMerge.relayKey)).count == 1
        let reason = relaysDidNotAnswer(answeredBy: lookup.answeredBy, own: ListMerge.followCounted(own: own))
        guard case .relaysDidNotAnswer(let ownAnswered, let ownCount) = reason else { return reason }
        if oneRelay { return ownAnswered < ownCount ? .oneRelayList : reason }
        return ownAnswered < 2 ? .tooFewAnswered(answered: ownAnswered) : reason
    }

    /// How many of the account's `own` relays are in `answeredBy`, as
    /// ListMerge.editBase counts them.
    static func relaysDidNotAnswer(answeredBy: Set<String>, own: [String]) -> FollowPublishFailure {
        let mine = Set(own.map(ListMerge.relayKey))
        let answered = mine.intersection(Set(answeredBy.map(ListMerge.relayKey))).count
        return .relaysDidNotAnswer(ownAnswered: answered, own: mine.count)
    }
}
