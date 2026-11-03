import Foundation

/// Save for later: lane C, after the Bookmarks list (kind 10003) lands. Must write through that list's store, never its own.
/// Phase 1 stub: the review card says "Not ready yet".
struct BookmarkShareHandler: SharePortalHandler {
    let action = NVShareAction.bookmark
}
