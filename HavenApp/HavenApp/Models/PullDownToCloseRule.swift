import Foundation

/// When a pull-down on the post page closes it, like dismissing a sheet.
///
/// The page has no refresh pull (it updates live). A downward pull that began
/// with the page already at its top, and went far enough past the top, closes
/// it. A pull that began mid-page only ever scrolls, even if it runs up past
/// the top: the reader was scrolling, not asking to leave.
enum PullDownToCloseRule {
    /// How far past the top (points) the pull has to go when the finger lifts.
    static let closeDistance: Double = 90
    /// Slack for "at the top": rounding in the scroll offset.
    static let topSlack: Double = 1

    /// `overscroll` is how far the content sits below its top position,
    /// positive when pulled down past the top.
    static func isAtTop(overscroll: Double) -> Bool {
        overscroll >= -topSlack
    }

    static func shouldClose(startedAtTop: Bool, overscrollAtRelease: Double) -> Bool {
        startedAtTop && overscrollAtRelease >= closeDistance
    }
}
