import Foundation

/// Column maths for the GIF picker's grid.
///
/// The grid draws cells of different heights -- a Tenor GIF is any shape, and
/// a getyarn clip carries a caption whose depth depends on the transcript --
/// so a row-based grid leaves a ragged gap under every short cell in a row.
/// This lays the cells out as a waterfall instead: fixed-width columns, each
/// item placed in whichever column is currently shortest.
///
/// Kept free of SwiftUI so it can be tested directly; the view supplies the
/// measured width and the per-item height.
enum GifGridLayout {
    /// Narrowest a cell may be. Below this a Tenor GIF stops being legible as
    /// a preview -- it is an animation being judged at a glance, not a thumbnail.
    static let minColumnWidth: Double = 150
    static let spacing: Double = 8
    /// A cap, not a target. Without it a wide macOS window draws eight columns
    /// of postage stamps.
    static let maxColumns: Int = 5

    /// How many columns of at least `minColumnWidth` fit in `width`, counting
    /// the gaps between them. Always at least one, so a very narrow sheet
    /// still draws something rather than dividing by zero.
    static func columnCount(
        forWidth width: Double,
        minColumnWidth: Double = minColumnWidth,
        spacing: Double = spacing,
        maxColumns: Int = maxColumns
    ) -> Int {
        guard width > 0, minColumnWidth > 0 else { return 1 }
        let fitting = Int((width + spacing) / (minColumnWidth + spacing))
        return max(1, min(maxColumns, fitting))
    }

    /// Width of one column once the gaps are taken out.
    static func columnWidth(
        forWidth width: Double,
        columns: Int,
        spacing: Double = spacing
    ) -> Double {
        guard columns > 0 else { return max(0, width) }
        let gaps = spacing * Double(columns - 1)
        return max(0, (width - gaps) / Double(columns))
    }

    /// Deals `items` into `columns` columns, each one going to the column that
    /// is shortest so far.
    ///
    /// Ties go to the leftmost column, which matters more than it looks: it
    /// means the first `columns` items fill the top row left to right, so the
    /// most relevant results still read across the top before the layout
    /// starts optimising for balance.
    ///
    /// Order within a column is preserved, and every item lands in exactly one
    /// column.
    static func distribute<T>(
        _ items: [T],
        columns: Int,
        height: (T) -> Double
    ) -> [[T]] {
        let count = max(1, columns)
        var buckets: [[T]] = Array(repeating: [], count: count)
        var filled = [Double](repeating: 0, count: count)

        for item in items {
            var shortest = 0
            for index in 1..<count where filled[index] < filled[shortest] - 0.0001 {
                shortest = index
            }
            buckets[shortest].append(item)
            // A non-finite or negative height would poison the running totals
            // and pin every later item to one column.
            let measured = height(item)
            filled[shortest] += (measured.isFinite && measured > 0) ? measured + spacing : spacing
        }
        return buckets
    }
}
