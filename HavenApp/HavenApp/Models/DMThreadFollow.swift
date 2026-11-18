import CoreGraphics

/// When a chat scrolls itself to the newest message.
///
/// Someone who has scrolled up to read older messages stays where they are
/// when a message arrives. At (or near) the bottom the chat keeps following
/// new messages, and a message you just sent always brings you down to it.
enum DMThreadFollow {
    /// How far above the very bottom still counts as "at the bottom", in
    /// points. Covers the list's bottom padding and a small nudge of the
    /// finger, but not a deliberate scroll up.
    static let nearBottomSlack: CGFloat = 80

    /// Whether the end of the list is on screen (within the slack).
    /// `bottomMarkerY` is the top of the end-of-list marker measured from the
    /// top of the visible scroll area; `visibleHeight` is that area's height.
    static func isNearBottom(bottomMarkerY: CGFloat, visibleHeight: CGFloat) -> Bool {
        bottomMarkerY <= visibleHeight + nearBottomSlack
    }

    /// Whether to scroll to the bottom after the message list changed.
    /// - Parameters:
    ///   - wasNearBottom: the reader was at the bottom before the change.
    ///   - previousNewestID: id of the newest message before the change.
    ///   - newestID: id of the newest message now.
    ///   - newestIsFromMe: the newest message now is one you sent.
    static func shouldFollow(wasNearBottom: Bool,
                             previousNewestID: String?,
                             newestID: String?,
                             newestIsFromMe: Bool) -> Bool {
        if wasNearBottom { return true }
        // Older messages loaded above don't change the newest one, so they
        // never pull you down; your own new message does.
        return newestID != nil && newestID != previousNewestID && newestIsFromMe
    }
}
