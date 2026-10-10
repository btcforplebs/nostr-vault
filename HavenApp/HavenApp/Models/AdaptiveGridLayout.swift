import Foundation

/// Column maths for the grids that are laid out from the room they have — the
/// profile and feed media grids, the Vault's media tab, the Blossom picker.
///
/// A fixed count is a bet on one screen width. Three across is right on a
/// phone and wrong on an iPad, where the same three tiles become billboards;
/// and the pane a grid sits in is not the screen anyway — an iPad sheet, a
/// split-view column and a full window are three different widths of the same
/// grid.
///
/// Kept free of SwiftUI so it can be tested directly; the view supplies the
/// measured width. See `AdaptiveLayout` for the platform rules on top of this.
enum AdaptiveGridLayout {
    /// How many tiles of about `ideal` points across fit in `width`, counting
    /// the gaps between them, never fewer than `minimum` and never more than
    /// `maximum`.
    ///
    /// A `width` of 0 means "not measured, or a platform that does not measure"
    /// and returns `minimum`, which every call site sets to the count the phone
    /// has always drawn. So an unmeasured first frame draws the old layout
    /// rather than a one-column flash.
    static func columnCount(forWidth width: Double, ideal: Double, spacing: Double,
                            minimum: Int, maximum: Int) -> Int {
        guard width > 0, ideal > 0, maximum >= minimum else { return minimum }
        let fitting = Int((width + spacing) / (ideal + spacing))
        return min(max(fitting, minimum), maximum)
    }

    /// Width of one tile once the gaps are taken out.
    static func tileWidth(forWidth width: Double, columns: Int, spacing: Double) -> Double {
        guard columns > 0 else { return width }
        return (width - spacing * Double(columns - 1)) / Double(columns)
    }
}
