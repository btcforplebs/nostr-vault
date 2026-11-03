import SwiftUI

/// Status (§6.4): NIP-38 "what I'm playing", public, expires on its own.
struct StatusShareHandler: SharePortalHandler {
    let action = NVShareAction.status

    func review(_ intent: NVShareIntent, close: @escaping () -> Void) -> AnyView {
        AnyView(StatusReviewView(intent: intent, close: close))
    }
}
