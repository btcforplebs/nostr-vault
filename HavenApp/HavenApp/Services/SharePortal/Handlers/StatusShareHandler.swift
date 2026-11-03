import Foundation

/// Now-playing status (kind 30315): lane C. Public; the card must say so.
/// Phase 1 stub: the review card says "Not ready yet".
struct StatusShareHandler: SharePortalHandler {
    let action = NVShareAction.status
}
