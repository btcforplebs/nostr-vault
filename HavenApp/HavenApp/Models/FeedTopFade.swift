import Foundation

/// The fade behind the iPhone feed's top pills and the clock. It is the
/// system's soft scroll edge (`softTopScrollEdge`), the one note detail
/// uses. A page-colour band drawn by the feed did this before (Logen
/// 2026-11-08), but it fell from 0.7 to clear in the last ~13 pt above the
/// posts, which read as a hard line (Logen 2026-11-11). The edge stays off
/// over Reels, whose video runs edge to edge, and under the iPad's floating
/// bar, which has its own edge.
///
/// Pure Foundation so MediaLogicTests can test it.
enum FeedTopFade {
    /// Whether the feed shows the soft top edge.
    static func shows(isReels: Bool, floatingBar: Bool) -> Bool {
        !isReels && !floatingBar
    }
}
