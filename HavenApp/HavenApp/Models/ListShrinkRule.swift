import Foundation

/// One version of a list as the vault keeps it (haven-go list_history.go),
/// free of the app's event type so the rules below are testable on their own.
struct ListVersion: Equatable, Identifiable {
    let id: String
    let pubkey: String
    let kind: Int
    let createdAt: Int64
    let tags: [[String]]
    let content: String

    /// The `d` tag of an addressable list (kinds 30000-39999), else "".
    var d: String {
        guard kind >= 30000, kind < 40000 else { return "" }
        return tags.first { $0.count >= 2 && $0[0] == "d" }?[1] ?? ""
    }
}

/// Which lists the vault keeps old versions of, and when a new version looks
/// like a wipe. Twin of haven-go `list_shrink.go` and Android
/// `ListShrinkRule.kt`: the kind set and the rule must stay the same in all
/// three (RESEARCH/NV_LIST_PROTECTION_PLAN.md, Logen 2026-11-02).
enum ListShrinkRule {
    /// Kind 0 is not a list but is kept the same way; its items are the
    /// profile's filled-in fields.
    static let protectedKinds: [Int] = [0, 3, 10000, 10001, 10002, 10003, 10004, 10006, 10007,
                                        10015, 10030, 10050, 10063, 30000, 30002, 30003, 30030]

    /// Lists with an encrypted private part the vault can't read: a large
    /// drop in content length counts too.
    static let encryptedKinds: Set<Int> = [10000, 10003, 30000, 30003]

    /// Tags naming or describing a list rather than being an item in it.
    static let metadataTags: Set<String> = ["d", "title", "name", "description", "image", "alt", "client"]

    /// A list this size or larger is a wipe when it loses more than half.
    static let minItems = 10
    /// The same for an encrypted part, in characters of content.
    static let minContent = 1000

    static func isProtected(_ kind: Int) -> Bool { protectedKinds.contains(kind) }

    /// What the person calls the list.
    static func name(_ kind: Int) -> String {
        switch kind {
        case 0: return "profile"
        case 3: return "follows"
        case 10000: return "mutes"
        case 10001: return "pinned notes"
        case 10002: return "relay list"
        case 10003: return "bookmarks"
        case 10004: return "communities"
        case 10006: return "blocked relays"
        case 10007: return "search relays"
        case 10015: return "interests"
        case 10030: return "emoji list"
        case 10050: return "DM relays"
        case 10063: return "media servers"
        case 30000: return "follow set"
        case 30002: return "relay set"
        case 30003: return "bookmark set"
        case 30030: return "emoji set"
        default: return "list \(kind)"
        }
    }

    /// The public items of a list by (name, value), or a profile's filled-in
    /// fields by (field, value).
    static func items(_ v: ListVersion) -> Set<String> {
        if v.kind == 0 {
            guard let data = v.content.data(using: .utf8),
                  let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
            var out = Set<String>()
            for (key, value) in fields {
                if value is NSNull { continue }
                if let text = value as? String {
                    if !text.isEmpty { out.insert(key + "\u{0}" + text) }
                } else {
                    out.insert(key + "\u{0}" + String(describing: value))
                }
            }
            return out
        }
        var out = Set<String>()
        for tag in v.tags {
            guard let name = tag.first, !metadataTags.contains(name) else { continue }
            out.insert(tag.count > 1 ? name + "\u{0}" + tag[1] : name)
        }
        return out
    }

    /// How many items: every tag but the metadata ones, or a profile's
    /// filled-in fields. Counted as the vault counts them (one per tag).
    static func itemCount(_ v: ListVersion) -> Int {
        if v.kind == 0 { return items(v).count }
        return v.tags.filter { tag in tag.first.map { !metadataTags.contains($0) } ?? false }.count
    }

    /// Whether `next`, the version after `prev`, looks like a wipe rather
    /// than an edit: empty where `prev` was not, or under half of a list of
    /// `minItems` or more. For an encrypted list the content counts the same
    /// way, by length.
    static func shrank(_ prev: ListVersion, _ next: ListVersion) -> Bool {
        let old = itemCount(prev), new = itemCount(next)
        if old > 0 && new == 0 { return true }
        if old >= minItems && new * 2 < old { return true }
        if encryptedKinds.contains(prev.kind) {
            let oldLen = prev.content.count, newLen = next.content.count
            if oldLen > 0 && newLen == 0 { return true }
            if oldLen >= minContent && newLen * 2 < oldLen { return true }
        }
        return false
    }

    /// Whether `v` still holds everything in `than`: every public item and,
    /// for an encrypted list, at least as long a content (the private part
    /// can't be read here either without decrypting).
    static func holds(_ v: ListVersion, _ than: ListVersion) -> Bool {
        guard items(than).isSubset(of: items(v)) else { return false }
        if encryptedKinds.contains(than.kind) && v.content.count < than.content.count { return false }
        return true
    }
}
