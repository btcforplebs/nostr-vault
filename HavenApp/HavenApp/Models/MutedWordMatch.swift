import Foundation

/// Whole-word matching for muted words (and clean mode): a word or phrase
/// matches only where it is not part of a longer word, in any case. "ass"
/// hides "Ass!" but not "class". Letters and digits of any script count as
/// part of a word. A word that starts or ends with another character
/// ("c++", "#tag") needs no boundary on that side. Runs of white space in the
/// text count as one space, so a muted phrase still matches across a line
/// break. Same rule as web `muted-words.js` and Android `MutedWordMatch.kt`.
enum MutedWordMatch {
    static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    /// Whether `text` holds `word` (already lowercased, as MuteList keeps
    /// them) as a whole word.
    static func contains(_ text: String, word: String) -> Bool {
        guard !word.isEmpty, !text.isEmpty else { return false }
        let haystack = word.contains(" ") ? collapsedSpaces(text) : text
        let needsStart = word.first.map(isWordCharacter) ?? false
        let needsEnd = word.last.map(isWordCharacter) ?? false
        var from = haystack.startIndex
        while from < haystack.endIndex,
              let r = haystack.range(of: word, options: [.caseInsensitive], range: from..<haystack.endIndex) {
            let startOK = !needsStart || r.lowerBound == haystack.startIndex
                || !isWordCharacter(haystack[haystack.index(before: r.lowerBound)])
            let endOK = !needsEnd || r.upperBound == haystack.endIndex || !isWordCharacter(haystack[r.upperBound])
            if startOK && endOK { return true }
            from = haystack.index(after: r.lowerBound)
        }
        return false
    }

    static func containsAny(_ text: String, words: [String]) -> Bool {
        guard !text.isEmpty else { return false }
        return words.contains { contains(text, word: $0) }
    }

    private static func collapsedSpaces(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }
}
