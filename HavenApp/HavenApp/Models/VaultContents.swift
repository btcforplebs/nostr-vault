import Foundation

/// What the vault holds, grouped the way the Vault tab names things. Built
/// from NIP-45 COUNTs against the vault's own relays (see
/// `VaultContentsModel`), so every number is one the relay gave.
///
/// The dashboard used to show four tiles counted one way, a Storage section
/// and a "What's stored" page under Advanced counted another, and a per-kind
/// sheet a third. This is the one source for all of them.
struct VaultContents: Equatable {
    struct Group: Identifiable, Equatable {
        let id: String
        let title: String
        let icon: String
        let kinds: [Int]
        /// False where "by you" means nothing: a gift wrap is signed by a
        /// throwaway key and a zap receipt by the payer's wallet server.
        var countsYours = true
    }

    /// One group's line: its total, how many of those you signed, and its
    /// kinds that hold anything.
    struct GroupRow: Identifiable, Equatable {
        let group: Group
        let count: Int
        let yours: Int?
        let kinds: [KindRow]
        var id: String { group.id }
    }

    struct KindRow: Identifiable, Equatable {
        /// The kind, or nil for the events whose kind was not asked about.
        let kind: Int?
        let count: Int
        var id: Int { kind ?? -1 }
        var title: String { kind.map(VaultContents.kindName) ?? "Kinds not listed" }
    }

    /// The vault's groups, in the order the dashboard lists them. Notes holds
    /// the kinds the Vault tab's Notes list shows (`VaultNoteScope.notes`
    /// over `NostrService.relayTabNoteKinds`); Articles and Highlights are
    /// its other two scopes.
    static let groups: [Group] = [
        Group(id: "notes", title: "Notes", icon: "doc.text", kinds: [1, 6, NIP10Thread.commentKind, NIP88Poll.kind]),
        Group(id: "articles", title: "Articles", icon: "doc.richtext", kinds: [VaultNoteScope.articleKind, 30024]),
        Group(id: "highlights", title: "Highlights", icon: "highlighter", kinds: [VaultNoteScope.highlightKind]),
        Group(id: "reactions", title: "Reactions", icon: "heart.fill", kinds: [7]),
        Group(id: "zaps", title: "Zaps", icon: "bolt.fill", kinds: [9734, 9735], countsYours: false),
        Group(id: "messages", title: "Messages", icon: "envelope.fill", kinds: [4, 1059], countsYours: false),
        Group(id: "profile", title: "Profile and lists", icon: "person.crop.circle",
              kinds: [0, 3, 10000, 10001, 10002, 10003, 10005, 10006, 10015, 10030, 10050, 10063,
                      30000, 30001, 30002, 30003]),
    ]

    /// Kinds counted one by one beyond the groups, so "Other" can say what
    /// it holds instead of only how much.
    static let otherKinds = [5, 8, 9, 16, 20, 21, 22, 1063, 1311, 1808, 30008, 30009, 30030, 30078]

    /// Every kind asked about.
    static var countedKinds: [Int] { groups.flatMap(\.kinds) + otherKinds }

    static func kindName(_ kind: Int) -> String {
        kindNames[kind] ?? "Kind \(kind)"
    }

    private static let kindNames: [Int: String] = [
        0: "Profile", 1: "Short notes", 3: "Follow list", 4: "Direct messages (old style)",
        5: "Deletions", 6: "Reposts", 7: "Reactions", 8: "Badge awards", 9: "Chat messages",
        16: "Generic reposts", 20: "Pictures", 21: "Videos", 22: "Short videos",
        1059: "Gift-wrapped messages", 1063: "File details", 1068: "Polls", 1111: "Comments",
        1311: "Live chat", 1808: "Audio tracks", 9734: "Zap requests", 9735: "Zap receipts",
        9802: "Highlights", 10000: "Mute list", 10001: "Pinned notes", 10002: "Relay list",
        10003: "Bookmarks", 10005: "Public chats", 10006: "Blocked relays", 10015: "Interests",
        10030: "Emoji list", 10050: "Message relays", 10063: "Media servers",
        30000: "People lists", 30001: "Generic lists", 30002: "Relay sets", 30003: "Bookmark sets",
        30008: "Profile badges", 30009: "Badge definitions", 30023: "Articles", 30024: "Article drafts",
        30030: "Emoji sets", 30078: "App data",
    ]

    /// Every event in the vault.
    let total: Int
    /// Kind → count, for every kind in `countedKinds`.
    let byKind: [Int: Int]
    /// Group id → events of that group signed by you.
    let yours: [String: Int]

    var groupRows: [GroupRow] {
        let named = Self.groups.map { group in
            GroupRow(
                group: group,
                count: group.kinds.reduce(0) { $0 + (byKind[$1] ?? 0) },
                yours: group.countsYours ? yours[group.id] ?? 0 : nil,
                kinds: kindRows(group.kinds))
        }
        let namedTotal = named.reduce(0) { $0 + $1.count }
        var otherKinds = kindRows(Self.otherKinds)
        let listed = otherKinds.reduce(0) { $0 + $1.count }
        let unlisted = max(0, total - namedTotal - listed)
        if unlisted > 0 {
            otherKinds.append(KindRow(kind: nil, count: unlisted))
            otherKinds.sort { $0.count > $1.count }
        }
        let other = GroupRow(
            group: Group(id: "other", title: "Other", icon: "ellipsis.circle", kinds: Self.otherKinds, countsYours: false),
            count: max(0, total - namedTotal),
            yours: nil,
            kinds: otherKinds)
        return (named + [other]).filter { $0.count > 0 }
    }

    /// The kinds that hold anything, largest first.
    private func kindRows(_ kinds: [Int]) -> [KindRow] {
        kinds.compactMap { kind in
            let count = byKind[kind] ?? 0
            return count > 0 ? KindRow(kind: kind, count: count) : nil
        }
        .sorted { $0.count > $1.count }
    }
}
