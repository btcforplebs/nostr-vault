import SwiftUI

/// Label (§6.5): NIP-32 label on a link in our namespace; public.
struct LabelShareHandler: SharePortalHandler {
    let action = NVShareAction.label

    func review(_ intent: NVShareIntent, close: @escaping () -> Void) -> AnyView {
        AnyView(LabelReviewView(intent: intent, close: close))
    }
}
