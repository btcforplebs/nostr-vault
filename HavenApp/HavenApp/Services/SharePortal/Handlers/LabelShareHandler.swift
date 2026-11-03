import Foundation

/// Flag a link (NIP-32 kind 1985): lane C. Labels and namespace are Logen's pick.
/// Phase 1 stub: the review card says "Not ready yet".
struct LabelShareHandler: SharePortalHandler {
    let action = NVShareAction.label
}
