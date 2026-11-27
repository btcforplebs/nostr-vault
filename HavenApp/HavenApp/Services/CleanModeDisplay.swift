import Foundation

/// Where clean mode meets the screens: the setting, the shipped list, and
/// masking for the text and names they draw (`CleanMode`).
extension CleanMode {
    /// Off by default. Read on every draw, so a change shows as text is next drawn.
    static var isOn: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    /// The shipped list, read once.
    static let shippedWords: Set<String> = {
        guard let url = Bundle.main.url(forResource: "clean-words-en", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return words(fromList: text)
    }()

    /// `text` as shown: masked when clean mode is on.
    static func shown(_ text: String) -> String {
        isOn ? mask(text, words: shippedWords) : text
    }

    /// Formatted text as shown: masked when clean mode is on. Each run keeps
    /// its attributes, so a link's target is never touched and still opens.
    static func shown(_ attributed: AttributedString) -> AttributedString {
        guard isOn else { return attributed }
        let words = shippedWords
        var out = AttributedString()
        var changed = false
        for run in attributed.runs {
            let piece = attributed[run.range]
            let text = String(piece.characters)
            let masked = mask(text, words: words)
            if masked != text {
                changed = true
                out.append(AttributedString(masked, attributes: run.attributes))
            } else {
                out.append(AttributedString(piece))
            }
        }
        return changed ? out : attributed
    }
}

extension FeedProfile {
    /// `bestName` as drawn: masked when clean mode is on (Logen 2026-11-27:
    /// names too). Search, mentions and anything sent keep `bestName`.
    var shownName: String { CleanMode.shown(bestName) }
}
