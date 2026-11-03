import Foundation

/// Pay or zap: lane D. Never pays without an explicit confirm; invoice expiry re-checked here. Tron review, mandatory.
/// Phase 1 stub: the review card says "Not ready yet".
struct PayShareHandler: SharePortalHandler {
    let action = NVShareAction.pay
}
