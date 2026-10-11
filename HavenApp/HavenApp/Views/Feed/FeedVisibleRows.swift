import SwiftUI

/// Which feed rows are on screen. Reference type on purpose: it changes on
/// every scroll, and nothing should re-render for that — it is read only when
/// the layout switches.
final class FeedVisibleRows {
    var ids: Set<String> = []
}

extension View {
    /// Keeps `rows` knowing whether this row is on screen.
    @ViewBuilder
    func trackFeedVisibility(_ id: String, in rows: FeedVisibleRows) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            self
                .onScrollVisibilityChange(threshold: 0.3) { visible in
                    if visible { rows.ids.insert(id) } else { rows.ids.remove(id) }
                }
                .onDisappear { rows.ids.remove(id) }
        } else {
            self
        }
    }
}
