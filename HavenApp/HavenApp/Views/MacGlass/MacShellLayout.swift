import CoreGraphics

/// The Mac window's column rules. Numbers come from the two apps this window
/// merges: the 68 pt rail and the 340 pt "Your space" column are the iPad's
/// (`BottomTabBar.railWidth`, `VaultActivityRow+Compact`), the reading width
/// and the "Thread" column are the web app's (`desktop.css`).
///
/// Pure, so the breakpoints can be tested without a window.
enum MacShellLayout {
    static let railWidth: CGFloat = 68
    /// The gap the floating rail and the cards keep from the window edge.
    static let inset: CGFloat = 10
    static let spaceWidth: CGFloat = 340
    /// The narrowest a list may get before a column beside it is dropped.
    static let listMinWidth: CGFloat = 460
    static let threadMinWidth: CGFloat = 420
    static let threadMaxWidth: CGFloat = 560
    /// Posts are read at this width, centred, however wide the window is.
    static let readingWidth: CGFloat = 720

    /// The rail with its insets: what every row loses on the left.
    static var railSlot: CGFloat { railWidth + inset * 2 }

    /// Whether an opened note sits beside the list. Below this it covers the
    /// list as a sheet, as it did before.
    static func threadBeside(windowWidth: CGFloat) -> Bool {
        windowWidth >= railSlot + listMinWidth + threadMinWidth + inset
    }

    static func threadWidth(windowWidth: CGFloat) -> CGFloat {
        let share = (windowWidth - railSlot) * 0.44
        return min(threadMaxWidth, max(threadMinWidth, share.rounded()))
    }

    /// "Your space" shows when asked for, when no thread has its column and
    /// when the list keeps its minimum width.
    static func showsSpace(windowWidth: CGFloat, wanted: Bool, threadOpen: Bool, pageAllows: Bool) -> Bool {
        guard wanted, pageAllows, !threadOpen else { return false }
        return windowWidth >= railSlot + listMinWidth + spaceWidth + inset
    }
}
