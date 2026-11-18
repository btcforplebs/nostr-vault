/// A chat belongs to the account it was opened as.
///
/// Switching account with a chat open must never let Send go out as the new
/// account to the old account's contact (A5, RESEARCH/NV_MESSAGES_UX_CHECK_2026_11_18.md).
/// The chat closes on a switch and drops its draft; this check is the last
/// line in case anything still reaches Send.
enum DMChatAccountGuard {
    /// Whether a chat opened as `openedAs` may still send while `active` is
    /// the signed-in account. An unknown account on either side refuses.
    static func maySend(openedAs: String?, active: String) -> Bool {
        guard let openedAs, !openedAs.isEmpty, !active.isEmpty else { return false }
        return openedAs == active
    }

    /// Whether an open chat (and its draft) has to close: the account it was
    /// opened as is no longer the signed-in one.
    static func mustClose(openedAs: String?, active: String) -> Bool {
        guard let openedAs, !openedAs.isEmpty else { return false }
        return openedAs != active
    }
}
