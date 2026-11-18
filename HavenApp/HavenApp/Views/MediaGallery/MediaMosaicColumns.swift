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
        let buckets = MediaMosaicLayout.distribute(items, columns: columns, spacing: Double(spacing)) {
            Self.aspect(of: $0)
        }
        HStack(alignment: .top, spacing: spacing) {
            ForEach(buckets.indices, id: \.self) { index in
                LazyVStack(spacing: rowSpacing) {
                    ForEach(buckets[index]) { item in
                        let aspect = MediaMosaicLayout.clampedAspect(Self.aspect(of: item))
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

    /// The media's shape as far as it is known before loading: the note's
    /// imeta `dim`, then the shape the local scan read from the file, then
    /// any hint a feed note left for this address. Nil draws a square.
    static func aspect(of item: MediaItem) -> Double? {
        let hash = MediaCacheService.blossomHash(in: item.url)
        let key = hash ?? item.url.absoluteString
        if let known = MediaMosaicSizes.shared.aspect(for: key) { return known }
        if let ratio = MediaMosaicLayout.aspect(tags: item.tags, url: item.url, hash: hash)
            ?? MediaHints.shared.hint(for: item.url)?.aspectRatio.map(Double.init) {
            MediaMosaicSizes.shared.record(ratio, for: key)
            return ratio
        }
        return nil
    }
}
