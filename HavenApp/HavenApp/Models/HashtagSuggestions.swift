import Foundation

/// Hashtags the people you follow use most, for the empty Hashtags feed.
enum HashtagSuggestions {
    /// Counts `t` tags across `notes` (each a note's tag array), once per
    /// note, merged by case. Drops tags already `followed`. Most used first,
    /// ties alphabetical, at most `limit`.
    static func top(_ notes: [[[String]]], excluding followed: Set<String>, limit: Int = 8) -> [String] {
        var counts: [String: Int] = [:]
        for tags in notes {
            var inNote = Set<String>()
            for tag in tags where tag.count >= 2 && tag[0] == "t" {
                let name = InterestList.normalize(tag[1])
                if !name.isEmpty { inNote.insert(name) }
            }
            for name in inNote { counts[name, default: 0] += 1 }
        }
        let followedNames = Set(followed.map(InterestList.normalize))
        return counts
            .filter { !followedNames.contains($0.key) }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .map(\.key)
    }
}
