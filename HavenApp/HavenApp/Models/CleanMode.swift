import Foundation

/// Clean mode: words from the built-in list (`docs/clean-words/en.txt`,
/// copied to Resources/clean-words-en.txt) shown as their first letter and
/// asterisks, same length, case kept (`Fuck` → `F***`). Whole words only, in
/// any case, so "class" and "Scunthorpe" are left alone (`MutedWordMatch`'s
/// word characters: letters and digits of any script). A local setting per
/// device, off by default, never published. It changes only what is drawn,
/// never the composer, drafts, what is sent or signed, search or stored
/// events. Web: net/clean-mode.js; Android: CleanMode.kt.
enum CleanMode {
    static let defaultsKey = "cleanMode"

    /// The list as shipped: one lowercase word per line.
    static func words(fromList text: String) -> Set<String> {
        Set(text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })
    }

    /// `text` with every whole word in `words` masked. Unchanged (the same
    /// string) when none is in it.
    static func mask(_ text: String, words: Set<String>) -> String {
        guard !words.isEmpty, !text.isEmpty else { return text }
        var out = ""
        var word = ""
        var changed = false
        func flush() {
            guard !word.isEmpty else { return }
            if words.contains(word.lowercased()), let first = word.first {
                out.append(first)
                out.append(String(repeating: "*", count: word.count - 1))
                changed = true
            } else {
                out.append(word)
            }
            word = ""
        }
        for c in text {
            if MutedWordMatch.isWordCharacter(c) {
                word.append(c)
            } else {
                flush()
                out.append(c)
            }
        }
        flush()
        return changed ? out : text
    }
}
