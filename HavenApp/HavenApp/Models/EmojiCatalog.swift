import Foundation

/// Every Unicode emoji with its name, read from the bundled `emoji.tsv`
/// (Unicode 15.0 + CLDR 43 English keywords, made by `scripts/gen-emoji-tsv.py`).
/// Pure, so the picker's sections and search are testable apart from the sheet.
/// Android twin (to come): the same `emoji.tsv` with an `EmojiCatalog.kt`.
struct EmojiCatalog: Equatable {
    struct Entry: Equatable {
        let emoji: String
        let name: String
        let keywords: [String]
    }

    struct Group: Equatable {
        let name: String
        /// SF Symbol for the picker's jump strip.
        let symbol: String
        let entries: [Entry]
    }

    let groups: [Group]
    /// Emoji to name, for VoiceOver.
    let names: [String: String]

    /// The 9 Unicode groups' short names and icons, in file order.
    private static let groupStyle: [String: (name: String, symbol: String)] = [
        "Smileys & Emotion": ("Smileys", "face.smiling"),
        "People & Body": ("People", "hand.raised"),
        "Animals & Nature": ("Nature", "leaf"),
        "Food & Drink": ("Food", "fork.knife"),
        "Travel & Places": ("Travel", "car"),
        "Activities": ("Activities", "soccerball"),
        "Objects": ("Objects", "lightbulb"),
        "Symbols": ("Symbols", "heart"),
        "Flags": ("Flags", "flag"),
    ]

    /// Parses the TSV: `#` comments, `@Group` headers, `emoji<TAB>name<TAB>keywords`.
    init(tsv: String) {
        var groups: [Group] = []
        var title: String?
        var entries: [Entry] = []
        func close() {
            guard let title, !entries.isEmpty else { return }
            let style = Self.groupStyle[title] ?? (title, "circle")
            groups.append(Group(name: style.name, symbol: style.symbol, entries: entries))
        }
        for line in tsv.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("@") {
                close()
                title = String(line.dropFirst())
                entries = []
                continue
            }
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count >= 2, !cols[0].isEmpty else { continue }
            let keywords = cols.count > 2
                ? cols[2].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                : []
            entries.append(Entry(emoji: String(cols[0]), name: String(cols[1]), keywords: keywords))
        }
        close()
        self.groups = groups
        var names: [String: String] = [:]
        for entry in groups.flatMap(\.entries) { names[entry.emoji] = entry.name }
        self.names = names
    }

    /// The app's copy, loaded once from the bundle. Empty if the file is missing.
    static let shared: EmojiCatalog = {
        guard let url = Bundle.main.url(forResource: "emoji", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return EmojiCatalog(tsv: "") }
        return EmojiCatalog(tsv: text)
    }()

    /// Emoji whose name or keywords match `query`, best first: whole name,
    /// name starts with it, a name word starts with it, a keyword starts with
    /// it, then the name contains it. Ties keep file order.
    func search(_ query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        var ranked: [(rank: Int, index: Int, emoji: String)] = []
        var index = 0
        for group in groups {
            for entry in group.entries {
                index += 1
                if let rank = Self.rank(entry, q) { ranked.append((rank, index, entry.emoji)) }
            }
        }
        return ranked.sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }.map(\.emoji)
    }

    private static func rank(_ entry: Entry, _ q: String) -> Int? {
        let name = entry.name.lowercased()
        if name == q { return 0 }
        if name.hasPrefix(q) { return 1 }
        let words = name.split { $0 == " " || $0 == ":" || $0 == "-" || $0 == "," }
        if words.contains(where: { $0.hasPrefix(q) }) { return 2 }
        if entry.keywords.contains(where: { $0.lowercased().hasPrefix(q) }) { return 3 }
        if name.contains(q) { return 4 }
        return nil
    }

    /// The query itself when it is only emoji (pasted or typed from the
    /// keyboard), so any emoji can be picked even if it is not in the list.
    static func typedEmoji(_ query: String) -> String? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4 else { return nil }
        let allEmoji = text.allSatisfy { ch in
            ch.unicodeScalars.contains { $0.properties.isEmojiPresentation }
                || (ch.unicodeScalars.count > 1 && ch.unicodeScalars.first?.properties.isEmoji == true)
        }
        return allEmoji ? text : nil
    }
}

extension EmojiCatalog {
    /// The Unicode groups as picker tabs.
    var tabs: [EmojiPickerTabs.Tab] {
        groups.map { group in
            EmojiPickerTabs.Tab(name: group.name, symbol: group.symbol, icon: nil, picks: group.entries.map { ReactionPick($0.emoji) })
        }
    }

    /// What the search box shows: the typed emoji itself, then custom emoji
    /// by shortcode (when `custom` is on), then Unicode by name. Once each.
    func results(_ query: String, tabs: [EmojiPickerTabs.Tab], custom: Bool) -> [ReactionPick] {
        var out: [ReactionPick] = []
        var seen = Set<String>()
        func add(_ pick: ReactionPick) { if seen.insert(pick.key).inserted { out.append(pick) } }
        if let typed = Self.typedEmoji(query) { add(ReactionPick(typed)) }
        if custom { EmojiPickerTabs.searchCustom(tabs, query: query).forEach(add) }
        search(query).forEach { add(ReactionPick($0)) }
        return out
    }
}
