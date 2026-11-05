import Foundation

/// Which path a notification marker from the relay takes, once it is allowed
/// by the account's preferences and the Web of Trust. A blocked author is
/// dropped first, for every type: the relay knows only the public blocks, and
/// the follow path used to return before the private-block check, so a
/// privately blocked person's follow still notified, with their name.
enum NotificationRoute: Equatable {
    case drop
    case dm
    case follow
    case note

    static func route(type: String, author: String, blocked: Set<String>) -> NotificationRoute {
        if BlockedPeople.isBlocked(author, in: blocked) { return .drop }
        switch type {
        case "dm", "giftwrap": return .dm
        case "follow": return .follow
        default: return .note
        }
    }
}
