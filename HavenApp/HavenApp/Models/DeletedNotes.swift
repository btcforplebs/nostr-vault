import Foundation

/// A note the rules below can hide: itself, or a repost of it.
protocol DeletableNote {
    var id: String { get }
    var repostedEventId: String? { get }
}

/// Keeping deleted posts gone. A relay that ignores NIP-09 still serves a
/// deleted post on a refresh, a reply thread fetches it back as the root,
/// and a repost or quote carries its text. These rules read your own
/// kind-5 requests (from this device or another) and hide their targets.
/// Twin: Android `DeletedNotes`.
enum DeletedNotes {
    static let requestKind = 5

    /// The posts a kind-5 request names: its `e` tags, hex ids only.
    static func targets(ofRequestTags tags: [[String]]) -> Set<String> {
        var ids = Set<String>()
        for tag in tags where tag.count >= 2 && tag[0] == "e" {
            let id = tag[1].lowercased()
            if id.count == 64, id.allSatisfy(\.isHexDigit) { ids.insert(id) }
        }
        return ids
    }

    /// Only your own requests count. Anyone can publish a kind 5 naming
    /// your post; relays ignore those, and so do we.
    static func isOwnRequest(kind: Int, pubkey: String, owner: String) -> Bool {
        kind == requestKind && !owner.isEmpty && pubkey == owner
    }

    /// Whether a row stays off screen: the deleted post, or a repost of it.
    static func hides(_ note: DeletableNote, deleted: Set<String>) -> Bool {
        guard !deleted.isEmpty else { return false }
        if deleted.contains(note.id) { return true }
        if let original = note.repostedEventId, deleted.contains(original) { return true }
        return false
    }

    static func visible<N: DeletableNote>(_ notes: [N], deleted: Set<String>) -> [N] {
        guard !deleted.isEmpty else { return notes }
        return notes.filter { !hides($0, deleted: deleted) }
    }

    /// A cache keyed by id, without the deleted posts under any key.
    static func visible<N: DeletableNote>(_ cache: [String: N], deleted: Set<String>) -> [String: N] {
        guard !deleted.isEmpty else { return cache }
        return cache.filter { !deleted.contains($0.key) && !hides($0.value, deleted: deleted) }
    }
}
