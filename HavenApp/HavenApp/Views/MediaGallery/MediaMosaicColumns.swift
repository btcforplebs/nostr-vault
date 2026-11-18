import SwiftUI

/// One run of the Vault's Media tab as a mosaic: fixed-width columns, each
/// tile as tall as its media's known shape (`MediaMosaicLayout`). Every tile
/// gets its final height before its photo loads, so nothing re-measures.
struct MediaMosaicColumns<Cell: View>: View {
    let items: [MediaItem]
    let columns: Int
    /// Zero until the grid's width is measured: tiles then size themselves
    /// from their shape alone for that first frame.
    let columnWidth: CGFloat
    let spacing: CGFloat
    let rowSpacing: CGFloat
    @ViewBuilder let cell: (MediaItem, Double) -> Cell

    var body: some View {
        // Each shape looked up once per pass, then dealt into columns.
        let tiles = items.map { Tile(item: $0, aspect: MediaMosaicLayout.clampedAspect(Self.aspect(of: $0))) }
        let buckets = MediaMosaicLayout.distribute(tiles, columns: columns, spacing: Double(spacing)) { $0.aspect }
        HStack(alignment: .top, spacing: spacing) {
            ForEach(buckets.indices, id: \.self) { index in
                LazyVStack(spacing: rowSpacing) {
                    ForEach(buckets[index]) { tile in
                        let item = tile.item, aspect = tile.aspect
                        if columnWidth > 0 {
                            cell(item, aspect)
                                .frame(width: columnWidth,
                                       height: MediaMosaicLayout.tileHeight(columnWidth: Double(columnWidth), aspect: aspect))
                        } else {
                            cell(item, aspect)
                                .aspectRatio(aspect, contentMode: .fit)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    /// The media's shape as far as it is known before loading: the shape the
    /// local scan read from the file, then the note's imeta `dim`, then any
    /// hint a feed note left for this address. Nil draws a square.
    static func aspect(of item: MediaItem) -> Double? {
        let sizes = MediaMosaicSizes.shared
        let address = item.url.absoluteString
        if let known = sizes.aspect(for: address) { return known }
        let hash = MediaCacheService.blossomHash(in: item.url)
        let found = hash.flatMap(sizes.aspect(for:))
            ?? MediaMosaicLayout.aspect(tags: item.tags, url: item.url, hash: hash)
            ?? MediaHints.shared.hint(for: item.url)?.aspectRatio.map(Double.init)
        // Kept under the address too, so the next pass skips the hash match.
        if let found { sizes.record(found, for: address) }
        return found
    }

    private struct Tile: Identifiable {
        let item: MediaItem
        let aspect: Double
        var id: UUID { item.id }
    }
}

/// The tab redraws on every filter, relay and feed change; the columns only
/// change when the run, the count or the width does. The cell closure only
/// reaches the parent's state, as with `MediaGridItem`.
extension MediaMosaicColumns: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.items == rhs.items && lhs.columns == rhs.columns && lhs.columnWidth == rhs.columnWidth
            && lhs.spacing == rhs.spacing && lhs.rowSpacing == rhs.rowSpacing
    }
}
