import Foundation

/// The account's own custom emoji: single `emoji` tags from its newest kind
/// 10030 (NIP-51) and the 30030 sets its `a` tags add.
struct EmojiLibrary: Codable, Equatable {
    struct EmojiSet: Codable, Equatable {
        let address: String
        let title: String
        let emojis: [CustomEmoji]
    }

    var owner: String = ""
    var single: [CustomEmoji] = []
    var sets: [EmojiSet] = []
}

/// Reading kinds 10030 and 30030. Pure, so it is testable apart from the
/// relays. Android: `EmojiListParse` in `service/EmojiListRepository.kt`.
enum EmojiListParse {
    struct SetRef: Equatable {
        let pubkey: String
        let d: String
    }

    /// A 10030's tags: valid `emoji` tags (first per shortcode) and its 30030 `a` refs.
    static func list(_ tags: [[String]]) -> (single: [CustomEmoji], setAddresses: [String]) {
        var seen = Set<String>()
        let addresses = tags.compactMap { tag -> String? in
            guard tag.count >= 2, tag[0] == "a", setRef(tag[1]) != nil, seen.insert(tag[1]).inserted else { return nil }
            return tag[1]
        }
        return (CustomEmoji.list(from: tags), addresses)
    }

    /// `30030:<64 hex>:<d>`, or nil. The `d` may itself hold colons.
    static func setRef(_ address: String) -> SetRef? {
        let parts = address.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "30030", parts[1].count == 64,
              parts[1].allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        return SetRef(pubkey: parts[1], d: parts[2])
    }

    /// A 30030's title and emoji, each tagged with the set's `address`.
    static func set(address: String, tags: [[String]]) -> EmojiLibrary.EmojiSet {
        func value(_ name: String) -> String? {
            tags.first { $0.count >= 2 && $0[0] == name && !$0[1].isEmpty }?[1]
        }
        let emojis = CustomEmoji.list(from: tags).map {
            CustomEmoji(shortcode: $0.shortcode, url: $0.url, setAddress: address)
        }
        return EmojiLibrary.EmojiSet(address: address, title: value("title") ?? value("d") ?? "Emoji set", emojis: emojis)
    }
}

/// The picker's tabs. Pure, so what shows where is testable apart from the sheet.
enum EmojiPickerTabs {
    struct Tab: Equatable {
        let name: String
        /// Drawn on the tab: an SF Symbol name for Unicode tabs, or the set's first emoji.
        let symbol: String?
        let icon: ReactionPick?
        let picks: [ReactionPick]
    }

    /// When `reacting`: Recents (if any), Your emoji (if any), one tab per set
    /// added, then `categories`. Otherwise `categories` alone, as before.
    static func build(categories: [Tab], palette: EmojiPalette.State, library: EmojiLibrary, reacting: Bool) -> [Tab] {
        guard reacting else { return categories }
        var out: [Tab] = []
        if !palette.recents.isEmpty {
            out.append(Tab(name: "Recents", symbol: "clock", icon: nil, picks: palette.recents))
        }
        if !library.single.isEmpty {
            out.append(Tab(name: "Your emoji", symbol: "star.fill", icon: nil, picks: library.single.map { ReactionPick($0) }))
        }
        for set in library.sets where !set.emojis.isEmpty {
            let picks = set.emojis.map { ReactionPick($0) }
            out.append(Tab(name: set.title, symbol: nil, icon: picks.first, picks: picks))
        }
        return out + categories
    }

    /// Custom emoji in any tab whose shortcode contains `query`, once each.
    static func searchCustom(_ tabs: [Tab], query: String) -> [ReactionPick] {
        var q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.hasPrefix(":") { q.removeFirst() }
        if q.hasSuffix(":") { q.removeLast() }
        guard !q.isEmpty else { return [] }
        var seen = Set<String>()
        return tabs.flatMap(\.picks).filter { pick in
            guard let shortcode = pick.shortcode, shortcode.lowercased().contains(q) else { return false }
            return seen.insert(pick.key).inserted
        }
    }
}
