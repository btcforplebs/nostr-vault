import SwiftUI

/// Recipe (§6.2): the page's JSON-LD Recipe saved as a local recipe draft. Nothing is published.
struct RecipeShareHandler: SharePortalHandler {
    let action = NVShareAction.recipe

    func review(_ intent: NVShareIntent, close: @escaping () -> Void) -> AnyView {
        AnyView(RecipeReviewView(intent: intent, close: close))
    }
}
