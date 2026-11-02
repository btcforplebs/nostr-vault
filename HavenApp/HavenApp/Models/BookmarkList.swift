import Foundation

/// NIP-51 bookmarks (kind 10003): the `e` tags for notes and `a` tags for
/// articles and other addressable events, public in the tags and private in
/// the encrypted content. A bookmark tap changes one entry and keeps every
/// other tag as it is (Logen 2026-11-02, plan db0353a6). Twin of Android
/// `BookmarkList.kt`.
enum BookmarkList {
    static let kind = 10003

    enum Entry: Hashable {
        /// A note by event id (lowercase hex).
        case event(String)
        /// An addressable event by "kind:pubkey:d".
        case address(String)

        var tag: [String] {
            switch self {
            case .event(let id): return ["e", id]
            case .address(let coordinate): return ["a", coordinate]
            }
        }

        /// The `a` coordinate's parts, for fetching it.
        var coordinate: (kind: Int, pubkey: String, d: String)? {
            guard case .address(let value) = self else { return nil }
            let parts = value.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, let kind = Int(parts[0]) else { return nil }
            return (kind, parts[1], parts[2])
        }
    }

    /// The entry for an event: its address when it is addressable (kinds
    /// 30000-39999, so an edited article stays bookmarked), else its id.
    static func entry(id: String, pubkey: String, kind: Int, tags: [[String]]) -> Entry {
        if (30000..<40000).contains(kind) {
            let d = tags.first { $0.count >= 2 && $0[0] == "d" }?[1] ?? ""
            return .address("\(kind):\(pubkey.lowercased()):\(d)")
        }
        return .event(id.lowercased())
    }

    /// The `e` or `a` tag as an entry; nil for any other tag.
    static func entry(tag: [String]) -> Entry? {
        guard tag.count >= 2, !tag[1].isEmpty else { return nil }
        switch tag[0] {
        case "e": return .event(tag[1].lowercased())
        case "a": return .address(tag[1])
        default: return nil
        }
    }

    /// The bookmarks in `tags`, newest first (NIP-51 appends new entries at
    /// the end), each once.
    static func entries(_ tags: [[String]]) -> [Entry] {
        var seen = Set<Entry>()
        return tags.reversed().compactMap(entry(tag:)).filter { seen.insert($0).inserted }
    }

    static func contains(_ tags: [[String]], _ entry: Entry) -> Bool {
        tags.contains { Self.entry(tag: $0) == entry }
    }

    /// `tags` with `entry` added at the end (`on`) or every copy of it taken
    /// out. Every other tag, unknown ones included, stays where it was, and
    /// adding one already there changes nothing.
    static func toggled(_ tags: [[String]], _ entry: Entry, on: Bool) -> [[String]] {
        if on { return contains(tags, entry) ? tags : tags + [entry.tag] }
        return tags.filter { Self.entry(tag: $0) != entry }
    }

    /// The private bookmarks: the decrypted content, a JSON array of tags.
    /// Empty when it is anything else.
    static func privateEntries(plaintext: String) -> [Entry] {
        guard let data = plaintext.data(using: .utf8),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [[Any]] else { return [] }
        return entries(array.map { $0.compactMap { $0 as? String } })
    }
}
