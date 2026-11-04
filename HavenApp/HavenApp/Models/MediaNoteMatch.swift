import Foundation

/// The notes that use one media file, for the media viewer's swipe up
/// (Logen 2026-11-04). The Vault viewer lists every note on the user's own
/// vault that names the file, by its URL or its sha256 (a Blossom name), in
/// the text or in any tag (imeta included), whoever wrote it. Nothing is
/// asked of the network: only what the vault already holds.
enum MediaNoteMatch {
    /// The kinds a post that carries media can be: notes, pictures, videos,
    /// file metadata, comments, articles, highlights, polls.
    static let kinds: Set<Int> = [1, 20, 21, 22, 1063, 1111, 30023, 9802, 1068, 34235, 34236]

    struct Note: Equatable {
        let id: String
        let kind: Int
        let createdAt: Int64
        let content: String
        let tags: [[String]]
    }

    /// The sha256 a Blossom URL is named by ("…/<64 hex>[.ext]"), lowercased.
    static func sha256(of url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        return name.count == 64 && name.allSatisfy(\.isHexDigit) ? name : nil
    }

    /// Whether a note uses the file: its URL, or its hash, in the text or a tag.
    static func uses(_ note: Note, url: String, sha256: String?) -> Bool {
        let needles = [url.lowercased()] + (sha256.map { [$0] } ?? [])
        func hit(_ text: String) -> Bool {
            let t = text.lowercased()
            return needles.contains { !$0.isEmpty && t.contains($0) }
        }
        return hit(note.content) || note.tags.contains { $0.contains(where: hit) }
    }

    /// Every note in `notes` that uses the file, newest first, each once.
    static func notes(using url: URL, in notes: [Note]) -> [Note] {
        let link = url.absoluteString
        let hash = sha256(of: url)
        var seen = Set<String>()
        return notes
            .filter { kinds.contains($0.kind) && uses($0, url: link, sha256: hash) && seen.insert($0.id).inserted }
            .sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id < $1.id }
    }
}
