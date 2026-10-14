import Foundation

/// What came in while the app was away, as the one bottom pill shows it
/// ("5 mentions · 2 zaps · 1 DM"). Coming back used to put up a top pill and
/// a sound for nearly every arrival the relay caught up on, one after another;
/// on that first load back they are gathered here instead (Logen, 2026-10-14).
///
/// Pure Foundation so MediaLogicTests can compile and test it directly.
struct ReturnSummary: Equatable {
    /// What the pill counts, in the order it lists them.
    enum Category: Int, CaseIterable, Comparable {
        case mention, reply, zap, dm, reaction, repost, follower, other

        static func < (a: Category, b: Category) -> Bool { a.rawValue < b.rawValue }

        /// The marker type an arrival pill was raised for (see
        /// `LocalNotificationService.handle`).
        init(type: String) {
            switch type {
            // A quote of your note is a mention of you (the Mentions switch governs it).
            case "mention", "quote":     self = .mention
            case "reply":                self = .reply
            case "zap":                  self = .zap
            case "dm", "giftwrap":       self = .dm
            case "reaction":             self = .reaction
            case "repost":               self = .repost
            case "follow", "followers":  self = .follower
            default:                     self = .other
            }
        }

        func label(_ count: Int) -> String {
            let one = count == 1
            switch self {
            case .mention:  return one ? "mention" : "mentions"
            case .reply:    return one ? "reply" : "replies"
            case .zap:      return one ? "zap" : "zaps"
            case .dm:       return one ? "DM" : "DMs"
            case .reaction: return one ? "reaction" : "reactions"
            case .repost:   return one ? "repost" : "reposts"
            case .follower: return one ? "new follower" : "new followers"
            case .other:    return one ? "update" : "updates"
            }
        }
    }

    /// Past this many kinds the rest fold into "+N more", so the pill stays
    /// one line on a phone.
    static let maxListed = 3

    private var keys: [Category: Set<String>] = [:]

    /// Counts one arrival once, however many times it is announced (a relay
    /// marker and the system alert for the same event). False when `key` was
    /// already counted.
    @discardableResult
    mutating func add(type: String, key: String) -> Bool {
        keys[Category(type: type), default: []].insert(key).inserted
    }

    var isEmpty: Bool { total == 0 }
    var total: Int { keys.values.reduce(0) { $0 + $1.count } }
    func count(_ category: Category) -> Int { keys[category]?.count ?? 0 }

    /// "5 mentions · 2 zaps · 1 DM"; past `maxListed` kinds, "… · +4 more".
    var text: String {
        let present = Category.allCases.filter { count($0) > 0 }
        var parts = present.prefix(Self.maxListed).map { "\(count($0)) \($0.label(count($0)))" }
        let rest = present.dropFirst(Self.maxListed).reduce(0) { $0 + count($1) }
        if rest > 0 { parts.append("+\(rest) more") }
        return parts.joined(separator: " · ")
    }

    /// The same, for VoiceOver: commas, not dots.
    var spokenText: String {
        Category.allCases.filter { count($0) > 0 }
            .map { "\(count($0)) \($0.label(count($0)))" }
            .joined(separator: ", ")
    }
}

/// When arrivals after a return are gathered into the bottom pill, and how
/// long that pill stays. Opens as the app comes back from the background;
/// arrivals inside it make no top pill and no sound of their own.
///
/// - Nothing arrives within `waitForFirst`: it closes, and anything later is
///   live and gets the ordinary top pill.
/// - Each arrival keeps it open `settle` longer, since the relay's catch-up
///   and the DM sync land in bursts over several seconds, but never past
///   `maximum` after the return: by then it is live traffic again.
/// - The pill stays at least `minimumShow` after the first arrival, so one
///   arriving just before the close is still readable.
struct ReturnWindow: Equatable {
    static let waitForFirst: TimeInterval = 12
    static let settle: TimeInterval = 6
    static let maximum: TimeInterval = 30
    static let minimumShow: TimeInterval = 6

    let returnedAt: Date
    private(set) var firstArrival: Date?
    private(set) var lastArrival: Date?

    init(returnedAt: Date) { self.returnedAt = returnedAt }

    /// Until when an arrival is gathered rather than shown as a top pill.
    var gathersUntil: Date {
        guard let lastArrival else { return returnedAt.addingTimeInterval(Self.waitForFirst) }
        return min(returnedAt.addingTimeInterval(Self.maximum), lastArrival.addingTimeInterval(Self.settle))
    }

    /// Until when the bottom pill shows. Nil while nothing has arrived: no pill.
    var showsUntil: Date? {
        guard let firstArrival else { return nil }
        return max(gathersUntil, firstArrival.addingTimeInterval(Self.minimumShow))
    }

    func gathers(at now: Date) -> Bool { now < gathersUntil }

    /// Records an arrival at `now`. False (and nothing recorded) once the
    /// window has closed.
    mutating func arrive(at now: Date) -> Bool {
        guard gathers(at: now) else { return false }
        if firstArrival == nil { firstArrival = now }
        lastArrival = now
        return true
    }
}
