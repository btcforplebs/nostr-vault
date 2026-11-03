import SwiftUI

// MARK: - Router
//
// action → handler. One handler file per action under Handlers/, so a phase 2
// lane works in its own files and never in this switch: every action already
// has its handler here, most of them stubs that say "Not ready yet".

@MainActor
protocol SharePortalHandler {
    var action: NVShareAction { get }
    /// False for actions that finish the moment they are claimed (today's
    /// photo/video upload). Everything else ends on a review card.
    var needsReview: Bool { get }
    /// Called once, when the intent is claimed, for `needsReview == false`.
    func handleOnClaim(_ intent: NVShareIntent)
    /// The review card's body. `close` removes the intent from the queue.
    func review(_ intent: NVShareIntent, close: @escaping () -> Void) -> AnyView
}

extension SharePortalHandler {
    var needsReview: Bool { true }
    func handleOnClaim(_ intent: NVShareIntent) {}
    func review(_ intent: NVShareIntent, close: @escaping () -> Void) -> AnyView {
        AnyView(NotReadyShareReviewView(intent: intent, close: close))
    }
}

@MainActor
enum SharePortalRouter {
    static func handler(for action: NVShareAction) -> SharePortalHandler {
        switch action {
        case .highlight: return HighlightShareHandler()
        case .bookmark: return BookmarkShareHandler()
        case .privateCopy: return PrivateCopyShareHandler()
        case .articleClip: return ArticleClipShareHandler()
        case .mediaPost: return MediaPostShareHandler()
        case .upload: return UploadShareHandler()
        case .recipe: return RecipeShareHandler()
        case .profile: return ProfileShareHandler()
        case .pay: return PayShareHandler()
        case .dm: return DMShareHandler()
        case .status: return StatusShareHandler()
        case .calendar: return CalendarShareHandler()
        case .label: return LabelShareHandler()
        }
    }
}
