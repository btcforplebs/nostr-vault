import SwiftUI

/// Article clip (§6.1): quote + link saved as a local article draft. Nothing is published.
struct ArticleClipShareHandler: SharePortalHandler {
    let action = NVShareAction.articleClip

    func review(_ intent: NVShareIntent, close: @escaping () -> Void) -> AnyView {
        AnyView(ArticleClipReviewView(intent: intent, close: close))
    }
}
