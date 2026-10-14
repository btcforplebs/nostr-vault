import Foundation

/// The Search tab's who/when filter. Search always runs Global; this narrows
/// what the stream shows and never re-runs it, so flipping a filter is
/// instant and costs the relays nothing.
struct SearchFilter: Equatable {
    enum Who: CaseIterable {
        case everyone, follows, you

        var label: String {
            switch self {
            case .everyone: return "Everyone"
            case .follows: return "People you follow"
            case .you: return "You"
            }
        }

        /// Fits the toolbar pill when the filter is on.
        var shortLabel: String {
            switch self {
            case .everyone: return "Everyone"
            case .follows: return "Follows"
            case .you: return "You"
            }
        }

        var icon: String {
            switch self {
            case .everyone: return "globe"
            case .follows: return "person.2"
            case .you: return "person.crop.circle"
            }
        }
    }

    enum When: CaseIterable {
        case anyTime, day, week, month

        var label: String {
            switch self {
            case .anyTime: return "Any time"
            case .day: return "Last 24 hours"
            case .week: return "Last week"
            case .month: return "Last month"
            }
        }

        var shortLabel: String {
            switch self {
            case .anyTime: return "Any time"
            case .day: return "24 h"
            case .week: return "Week"
            case .month: return "Month"
            }
        }

        var icon: String {
            switch self {
            case .anyTime: return "clock"
            case .day: return "clock.badge"
            case .week: return "calendar"
            case .month: return "calendar.badge.clock"
            }
        }

        /// How far back a note may be dated. `nil` means no limit.
        var window: TimeInterval? {
            switch self {
            case .anyTime: return nil
            case .day: return 24 * 60 * 60
            case .week: return 7 * 24 * 60 * 60
            case .month: return 30 * 24 * 60 * 60
            }
        }
    }

    var who: Who = .everyone
    var when: When = .anyTime

    static let all = SearchFilter()

    /// Whether anything is being filtered out. Drives the toolbar pill.
    var isActive: Bool { self != .all }

    /// Short text for the toolbar pill: "Follows", "Week", "You · 24 h".
    /// `nil` when nothing is filtered.
    var summary: String? {
        var parts: [String] = []
        if who != .everyone { parts.append(who.shortLabel) }
        if when != .anyTime { parts.append(when.shortLabel) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Spoken form for accessibility: "People you follow, Last week".
    var accessibilitySummary: String {
        isActive ? [who.label, when.label].joined(separator: ", ") : "No filter"
    }

    /// Whether a note or profile from `pubkey` passes the "who" filter.
    /// "You" with no signed-in account matches nothing rather than everyone.
    func allowsAuthor(_ pubkey: String, own: String?, follows: Set<String>) -> Bool {
        switch who {
        case .everyone: return true
        case .follows: return follows.contains(pubkey)
        case .you: return own.map { !$0.isEmpty && $0 == pubkey } ?? false
        }
    }

    /// Whether a note dated `date` passes the "when" filter.
    func allowsDate(_ date: Date, now: Date = Date()) -> Bool {
        guard let window = when.window else { return true }
        return now.timeIntervalSince(date) <= window
    }
}
