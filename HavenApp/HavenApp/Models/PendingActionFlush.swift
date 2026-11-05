import Foundation

/// What happens to the post, repost or delete still counting down when a new
/// one starts.
///
/// It used to be cancelled: the first post left the feed and was never sent,
/// with no message, so posting then reposting within the countdown silently
/// lost the post. Now it is sent at once — the user already said send, the
/// new action only cuts the undo window short.
enum PendingActionFlush: Equatable {
    /// Nothing was counting down.
    case nothing
    /// Send the earlier action now, then start the new one.
    case sendNow
    /// The earlier action was queued under another account: do not send it as
    /// this one. The switch listener normally gets there first; this covers
    /// the gap before it runs.
    case drop

    static func decide(hasPending: Bool, queuedAccount: String, activeAccount: String) -> PendingActionFlush {
        guard hasPending else { return .nothing }
        return queuedAccount == activeAccount ? .sendNow : .drop
    }
}
