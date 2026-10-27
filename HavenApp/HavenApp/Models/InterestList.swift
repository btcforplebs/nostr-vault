import Foundation

/// The hashtags an account follows: its NIP-51 interest list (kind 10015).
/// Other clients read and write the same list, so tags we don't touch
/// (`a` refs to interest sets, odd-cased `t`s) and the content (private
/// items) ride along unchanged on every publish.
struct InterestList: Codable, Equatable {
    var tags: [[String]] = []
    var content: String = ""
    var createdAt: Int64 = 0

    /// Followed hashtags, lowercase, in list order.
    var hashtags: [String] {
        var seen = Set<String>()
        return tags.compactMap { tag in
            guard tag.count >= 2, tag[0] == "t" else { return nil }
            let name = InterestList.normalize(tag[1])
            guard !name.isEmpty, seen.insert(name).inserted else { return nil }
            return name
        }
    }

    func contains(_ hashtag: String) -> Bool {
        hashtags.contains(InterestList.normalize(hashtag))
    }

    /// NIP-24: hashtags are lowercase, no leading '#'.
    static func normalize(_ hashtag: String) -> String {
        var name = hashtag.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix("#") { name.removeFirst() }
        return name.lowercased()
    }

    /// What a post's #hashtag may be: letters, digits, `_`, at least one letter.
    private static let hashtagPattern = try! NSRegularExpression(pattern: #"^[\p{L}\p{N}_]*\p{L}[\p{L}\p{N}_]*$"#)
    private static let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;#"))

    /// Many hashtags typed or pasted at once ("#bitcoin #nostr, art" or one
    /// per line), split on spaces, commas and '#'. `hashtags` are normalized,
    /// in typed order, each once; `rejected` are the pieces that can't be a
    /// hashtag ("#123", "c++"), as typed.
    static func parseHashtags(_ input: String) -> (hashtags: [String], rejected: [String]) {
        var hashtags: [String] = []
        var seen = Set<String>()
        var rejected: [String] = []
        for piece in input.components(separatedBy: separators) where !piece.isEmpty {
            let range = NSRange(piece.startIndex..., in: piece)
            if hashtagPattern.firstMatch(in: piece, range: range) != nil {
                let name = normalize(piece)
                if seen.insert(name).inserted { hashtags.append(name) }
            } else {
                rejected.append(piece)
            }
        }
        return (hashtags, rejected)
    }

    /// Adds or removes one hashtag. Removing drops every case variant of it;
    /// everything else stays as it was.
    func setting(_ hashtag: String, followed: Bool) -> InterestList {
        let name = InterestList.normalize(hashtag)
        guard !name.isEmpty else { return self }
        var copy = self
        if followed {
            if !contains(name) { copy.tags.append(["t", name]) }
        } else {
            copy.tags.removeAll { $0.count >= 2 && $0[0] == "t" && InterestList.normalize($0[1]) == name }
        }
        return copy
    }
}
