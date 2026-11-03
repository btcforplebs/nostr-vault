import Foundation

// What the share sheet and the app's review card call each action. One table
// so the sheet's row and the card's title never disagree.
extension NVShareAction {
    var title: String {
        switch self {
        case .highlight: return "Highlight"
        case .bookmark: return "Save for later"
        case .privateCopy: return "Keep a private copy"
        case .articleClip: return "Clip to an article draft"
        case .mediaPost: return "Picture or video post"
        case .upload: return "Add to the upload queue"
        case .recipe: return "Save as a recipe"
        case .profile: return "Follow, mute or add to a list"
        case .pay: return "Pay or zap"
        case .dm: return "Send privately"
        case .status: return "Share what I'm playing"
        case .calendar: return "Add to a calendar"
        case .label: return "Flag this link"
        }
    }

    var systemImage: String {
        switch self {
        case .highlight: return "highlighter"
        case .bookmark: return "bookmark"
        case .privateCopy: return "lock.doc"
        case .articleClip: return "doc.richtext"
        case .mediaPost: return "photo.on.rectangle"
        case .upload: return "tray.and.arrow.up"
        case .recipe: return "fork.knife"
        case .profile: return "person.crop.circle.badge.plus"
        case .pay: return "bolt"
        case .dm: return "envelope"
        case .status: return "music.note"
        case .calendar: return "calendar"
        case .label: return "flag"
        }
    }
}
