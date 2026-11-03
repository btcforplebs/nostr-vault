import Foundation

/// Follow, mute or add to a list: lane C. Kind 3 / 10000 writes go through the guarded follow path. Tron review.
/// Phase 1 stub: the review card says "Not ready yet".
struct ProfileShareHandler: SharePortalHandler {
    let action = NVShareAction.profile
}
