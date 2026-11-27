import SwiftUI

/// The Media list row's second line (A2): "2.4 MB · Video · 3 Nov". A file
/// with no size from this device or its note asks its server once when the
/// row comes on screen (`MediaSizeLookup`, Z1) and shows "—" until then.
/// Twin: Android `MediaListRow`'s size line.
struct MediaRowDetailLine: View {
    let item: MediaItem
    @State private var learned: Int64?

    private var typeLabel: String {
        if item.isAnimatedGIF { return "GIF" }
        switch item.type {
        case .image: return "Photo"
        case .video: return "Video"
        case .audio: return "Audio"
        case .unknown: return "File"
        }
    }

    private var hash: String? { MediaCacheService.blossomHash(in: item.url) }

    var body: some View {
        Text(MediaSizeOrder.rowLine(size: item.knownSize ?? learned, type: typeLabel, date: item.dateAdded))
            .font(.appSystem(size: 12))
            .foregroundColor(.secondary)
            .lineLimit(1)
            .task(id: item.url) {
                guard item.knownSize == nil, let hash else { return }
                if let known = MediaSizeLookup.shared.cached(hash: hash) { learned = known; return }
                learned = await MediaSizeLookup.shared.size(hash: hash, url: item.url)
            }
    }
}
