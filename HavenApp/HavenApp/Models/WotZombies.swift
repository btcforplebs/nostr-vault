import Foundation

/// Zombies in your web: follows who have signed nothing for 90+ days.
///
/// The vault works this out (haven-go/pkg/wot/zombies.go, read through
/// `WotZombiesC`): any signed event of any kind counts as alive, as Plebs vs.
/// Zombies has it, and the buckets are theirs. This side only decodes, keeps
/// the list to people still followed, and words it. Cleaning up happens on
/// Plebs vs. Zombies (`plebsVsZombiesURL`): this app never unfollows anyone
/// for it (Logen 2026-11-01).
enum WotZombies {
    static let freshDays = 90
    static let rottingDays = 180
    static let ancientDays = 365
    static let plebsVsZombiesURL = URL(string: "https://plebsvszombies.cc")!

    enum Bucket: String, Decodable, CaseIterable {
        case fresh, rotting, ancient

        var title: String {
            switch self {
            case .fresh: return "Fresh"
            case .rotting: return "Rotting"
            case .ancient: return "Ancient"
            }
        }

        var days: Int {
            switch self {
            case .fresh: return WotZombies.freshDays
            case .rotting: return WotZombies.rottingDays
            case .ancient: return WotZombies.ancientDays
            }
        }

        var daysText: String { "\(days)+ days" }
    }

    struct Zombie: Decodable, Identifiable, Equatable {
        let pubkey: String
        /// Unix seconds of the newest event found; 0 when none at all.
        let lastSeen: Int64
        let days: Int
        let bucket: Bucket
        var id: String { pubkey }

        enum CodingKeys: String, CodingKey {
            case pubkey, days, bucket
            case lastSeen = "last_seen"
        }
    }

    struct Report: Decodable, Equatable {
        let owner: String
        let follows: Int
        let zombies: [Zombie]
        let checkedAt: Int64

        enum CodingKeys: String, CodingKey {
            case owner, follows, zombies
            case checkedAt = "checked_at"
        }

        func count(_ bucket: Bucket) -> Int { zombies.filter { $0.bucket == bucket }.count }

        /// The report as it stands for someone following `following` now:
        /// anyone unfollowed since the check (here or in another app) is gone
        /// from the list and the counts.
        func keeping(following: Set<String>) -> Report {
            let kept = zombies.filter { following.contains($0.pubkey) }
            let dropped = zombies.count - kept.count
            return Report(owner: owner, follows: max(follows - dropped, 0), zombies: kept, checkedAt: checkedAt)
        }
    }

    /// `WotZombiesC`'s answer.
    struct State: Decodable, Equatable {
        let checking: Bool
        let report: Report?
        let error: String?

        init(checking: Bool, report: Report?, error: String? = nil) {
            self.checking = checking
            self.report = report
            self.error = error
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            checking = try c.decodeIfPresent(Bool.self, forKey: .checking) ?? false
            report = try c.decodeIfPresent(Report.self, forKey: .report)
            error = try c.decodeIfPresent(String.self, forKey: .error)
        }

        enum CodingKeys: String, CodingKey { case checking, report, error }

        static func decode(_ json: String) -> State? {
            guard let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(State.self, from: data)
        }
    }

    // MARK: - Words

    /// The card's line: "65 of your 1,053 follows have been quiet 90+ days".
    static func headline(quiet: Int, follows: Int) -> String {
        if quiet == 0 {
            return "None of your \(follows.formatted()) follows have been quiet \(freshDays)+ days"
        }
        let verb = quiet == 1 ? "has" : "have"
        return "\(quiet.formatted()) of your \(follows.formatted()) follows \(verb) been quiet \(freshDays)+ days"
    }

    /// The list's header: "65 quiet 90+ days, longest first".
    static func listHeader(quiet: Int) -> String {
        "\(quiet.formatted()) quiet \(freshDays)+ days, longest first"
    }

    /// "Last seen 2 yr 6 mo ago", "Last seen 11 months ago", or that nothing
    /// signed by them was found at all.
    static func lastSeenText(_ lastSeen: Int64, now: Date = Date()) -> String {
        guard lastSeen > 0 else { return "Nothing signed by them found" }
        let calendar = Calendar(identifier: .gregorian)
        let then = Date(timeIntervalSince1970: TimeInterval(lastSeen))
        let parts = calendar.dateComponents([.year, .month, .day], from: then, to: now)
        let years = max(parts.year ?? 0, 0), months = max(parts.month ?? 0, 0)
        if years > 0 {
            return months > 0 ? "Last seen \(years) yr \(months) mo ago" : "Last seen \(years) yr ago"
        }
        if months > 0 { return "Last seen \(months) \(months == 1 ? "month" : "months") ago" }
        let days = max(parts.day ?? 0, 0)
        return "Last seen \(days) \(days == 1 ? "day" : "days") ago"
    }
}
