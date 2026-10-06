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
