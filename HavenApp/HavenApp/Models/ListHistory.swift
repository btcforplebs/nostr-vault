import Foundation

/// Old versions of the person's lists, read from the vault's /lists relay,
/// and what the apps do with them: spot a wipe, compare, restore. Twin of
/// Android `ListHistory.kt` (RESEARCH/NV_LIST_PROTECTION_PLAN.md).
enum ListHistory {
    /// One list: a kind, and the `d` of an addressable one.
    struct Key: Hashable, Comparable {
        let kind: Int
        let d: String

        static func < (a: Key, b: Key) -> Bool {
            a.kind != b.kind ? a.kind < b.kind : a.d < b.d
        }
    }

    /// A wipe the person should hear about: `after` replaced `before`.
    struct Wipe: Equatable {
        let before: ListVersion
        let after: ListVersion
    }

    /// The versions grouped per list, newest first, one per id, protected
    /// kinds by `author` only.
    static func group(_ versions: [ListVersion], author: String) -> [Key: [ListVersion]] {
        var seen = Set<String>()
        var out: [Key: [ListVersion]] = [:]
        for v in versions where v.pubkey == author && ListShrinkRule.isProtected(v.kind) && seen.insert(v.id).inserted {
            out[Key(kind: v.kind, d: v.d), default: []].append(v)
        }
        for key in out.keys { out[key]?.sort(by: newerFirst) }
        return out
    }

    static func newerFirst(_ a: ListVersion, _ b: ListVersion) -> Bool {
        a.createdAt != b.createdAt ? a.createdAt > b.createdAt : a.id < b.id
    }

    /// The wipe the newest version made, if it made one: it shrank the
    /// version just before it. The version to offer back is the largest one
    /// since the wipe before that the newest shrank (a late, older copy may
    /// sit in between, as haven-go listHistoryToDrop), and one the newest
    /// doesn't already hold.
    static func latestWipe(_ newestFirst: [ListVersion]) -> Wipe? {
        guard newestFirst.count >= 2, ListShrinkRule.shrank(newestFirst[1], newestFirst[0]) else { return nil }
        let after = newestFirst[0]
        // This wipe's span ends at the wipe before it (not included).
        var end = newestFirst.count
        for w in 1..<(newestFirst.count - 1) where ListShrinkRule.shrank(newestFirst[w + 1], newestFirst[w]) {
            end = w
            break
        }
        var best = newestFirst[1]
        for v in newestFirst.dropFirst(2).prefix(max(0, end - 2))
        where ListShrinkRule.shrank(v, after) && ListShrinkRule.itemCount(v) > ListShrinkRule.itemCount(best) {
            best = v
        }
        return Wipe(before: best, after: after)
    }

    /// What restoring `old` over `current` changes, as item keys
    /// (ListShrinkRule.items): what comes back and what goes.
    static func diff(restoring old: ListVersion, over current: ListVersion?) -> (comeBack: Set<String>, go: Set<String>) {
        let was = ListShrinkRule.items(old)
        let now = current.map(ListShrinkRule.items) ?? []
        return (was.subtracting(now), now.subtracting(was))
    }

    /// The list a restore signs: `old`'s tags. Kind 3 keeps the current
    /// content (an old relay list may be stored there, PR875 N1); every other
    /// kind takes the old content, its encrypted private part included (it
    /// is encrypted to the same account, so it still opens).
    static func restored(_ old: ListVersion, current: ListVersion?) -> (tags: [[String]], content: String) {
        let content = old.kind == 3 ? (current?.content ?? old.content) : old.content
        return (old.tags, content)
    }

    /// How an item key reads on screen: its value (an npub-able hex, a URL,
    /// a word), or the field and value of a profile.
    static func label(_ key: String) -> String {
        let parts = key.split(separator: "\u{0}", maxSplits: 1).map(String.init)
        return parts.count == 2 ? "\(parts[0]): \(parts[1])" : key
    }
}
