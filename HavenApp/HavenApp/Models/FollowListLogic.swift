import Foundation

/// The two lists a profile's Following / Followers counts open.
enum FollowListTab: String, CaseIterable, Identifiable {
    case following
    case followers

    var id: String { rawValue }
    var title: String { self == .following ? "Following" : "Followers" }
}

/// Order inside each group. The groups themselves never mix.
enum FollowListSort: String, CaseIterable, Identifiable {
    /// Followed by the most people you follow first.
    case trusted
    /// Newest follow first.
    case recent
    /// Name A–Z.
    case name

    var id: String { rawValue }
    var title: String {
        switch self {
        case .trusted: return "Most trusted"
        case .recent: return "Recent"
        case .name: return "Name A–Z"
        }
    }
}

/// Where a person sits relative to the viewer, in display order.
enum FollowListGroup: Int, CaseIterable, Identifiable {
    case follows
    case webOfTrust
    case outside

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .follows: return "People you follow"
        case .webOfTrust: return "Your web of trust"
        case .outside: return "Outside your web of trust"
        }
    }
}

/// One person in a follow list.
struct FollowListPerson: Equatable {
    let pubkey: String
    /// Shown name, used for Name A–Z and search.
    let name: String
    /// NIP-05, searched alongside the name.
    var nip05: String = ""
    /// Larger is newer. For followers: when their list naming this profile was
    /// published. For following: position in the contact list, which grows as
    /// people are added.
    let recency: Int64
}

struct FollowListSection: Equatable {
    let group: FollowListGroup
    let people: [FollowListPerson]
}

enum FollowListLogic {
    /// Splits `people` into the three groups and orders each.
    ///
    /// - follows: who the viewer follows.
    /// - webOfTrust: the viewer's trust graph (the same set Global feed and
    ///   search ranking use). Follows win over it.
    /// - trustRank: position in the extended network, ranked by how many of
    ///   the viewer's follows follow them; lower is more trusted.
    /// - hidden: spam, dropped from every group.
    /// Empty groups are left out.
    static func sections(
        people: [FollowListPerson],
        follows: Set<String>,
        webOfTrust: Set<String>,
        trustRank: [String: Int],
        hidden: Set<String> = [],
        sort: FollowListSort,
        query: String = ""
    ) -> [FollowListSection] {
        var seen = Set<String>()
        var buckets: [FollowListGroup: [FollowListPerson]] = [:]
        for person in people where !hidden.contains(person.pubkey) && matches(person, query: query) {
            guard seen.insert(person.pubkey).inserted else { continue }
            let group: FollowListGroup
            if follows.contains(person.pubkey) {
                group = .follows
            } else if webOfTrust.contains(person.pubkey) || trustRank[person.pubkey] != nil {
                group = .webOfTrust
            } else {
                group = .outside
            }
            buckets[group, default: []].append(person)
        }
        return FollowListGroup.allCases.compactMap { group in
            guard let members = buckets[group], !members.isEmpty else { return nil }
            return FollowListSection(group: group, people: ordered(members, by: sort, trustRank: trustRank))
        }
    }

    static func ordered(_ people: [FollowListPerson], by sort: FollowListSort, trustRank: [String: Int]) -> [FollowListPerson] {
        switch sort {
        case .recent:
            return people.sorted { $0.recency != $1.recency ? $0.recency > $1.recency : byName($0, $1) }
        case .name:
            return people.sorted(by: byName)
        case .trusted:
            // Ranked people first, best rank first; the unranked keep the
            // newest-first order so the tail is still meaningful.
            return people.sorted { a, b in
                switch (trustRank[a.pubkey], trustRank[b.pubkey]) {
                case let (ra?, rb?) where ra != rb: return ra < rb
                case (.some, .none): return true
                case (.none, .some): return false
                default: return a.recency != b.recency ? a.recency > b.recency : byName(a, b)
                }
            }
        }
    }

    static func matches(_ person: FollowListPerson, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        return person.name.localizedCaseInsensitiveContains(q)
            || person.nip05.localizedCaseInsensitiveContains(q)
    }

    /// A count that may be short of the real number reads "48+".
    static func countText(_ count: Int, more: Bool) -> String {
        let short: String
        if count >= 1_000_000 {
            short = String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            short = String(format: "%.1fk", Double(count) / 1_000)
        } else {
            short = "\(count)"
        }
        guard more else { return short }
        return count == 0 ? "—" : short + "+"
    }

    /// A bio on two lines: line breaks become spaces so the two lines carry
    /// words, not blank space.
    static func bioLine(_ about: String?) -> String? {
        guard let about else { return nil }
        let flat = about
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return flat.isEmpty ? nil : flat
    }

    private static func byName(_ a: FollowListPerson, _ b: FollowListPerson) -> Bool {
        let order = a.name.localizedCaseInsensitiveCompare(b.name)
        return order == .orderedSame ? a.pubkey < b.pubkey : order == .orderedAscending
    }
}
