import Foundation

/// Which profile tabs sit on the bar and which go behind its "more" button.
/// The bar holds three kinds; every other kind on show is one tap away in the
/// "more" list. Pure so it can be unit tested; `ProfileSection` feeds it.
enum ProfileTabSplit {
    /// Kinds on the bar, not counting the "more" button.
    static let barSlots = 3

    /// `visible` in tab order; `pinned` the kinds that earn a bar slot, in the
    /// order they take them. Pinned kinds not on show free their slot for the
    /// next visible kind, so the bar is always full when there is enough to
    /// fill it. A single kind left over goes on the bar too: a "more" list of
    /// one is a slower way to reach it.
    static func split<T: Equatable>(visible: [T], pinned: [T]) -> (bar: [T], more: [T]) {
        if visible.count <= barSlots + 1 { return (visible, []) }
        var bar = pinned.filter { visible.contains($0) }
        bar = Array(bar.prefix(barSlots))
        for kind in visible where bar.count < barSlots && !bar.contains(kind) {
            bar.append(kind)
        }
        // Keep the bar in tab order, not pinned order.
        bar = visible.filter { bar.contains($0) }
        return (bar, visible.filter { !bar.contains($0) })
    }
}
