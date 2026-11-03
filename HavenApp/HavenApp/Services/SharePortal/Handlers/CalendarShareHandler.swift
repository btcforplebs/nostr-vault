import Foundation

/// Event to calendar (NIP-52): lane A.
/// Phase 1 stub: the review card says "Not ready yet".
struct CalendarShareHandler: SharePortalHandler {
    let action = NVShareAction.calendar
}
