import Foundation
import NaturalLanguage

/// A language the Global feed can be narrowed to. `code` is the ISO 639-1
/// code NLLanguageRecognizer reports (both Chinese scripts fold into "zh").
struct FeedLanguage: Identifiable, Hashable {
    let code: String
    var id: String { code }

    /// Name in the reader's own locale ("German" in English, "Deutsch" in German).
    var displayName: String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized(with: .current) ?? code
    }

    /// The languages offered in the picker, roughly by how much of each is
    /// on Nostr. Anything else can still be picked up through `preferred`.
    static let offered: [String] = [
        "en", "es", "pt", "de", "fr", "ja", "zh", "ko", "ru", "it",
        "nl", "tr", "pl", "uk", "fa", "ar", "id", "th", "vi", "hi",
        "sv", "cs",
    ]

    /// The device's own languages first, then the rest of `offered`.
    static var pickerList: [FeedLanguage] {
        let preferred = Locale.preferredLanguages.compactMap { FeedLanguageDetector.baseCode($0) }
        var seen = Set<String>()
        return (preferred + offered)
            .filter { seen.insert($0).inserted }
            .map(FeedLanguage.init(code:))
    }
}

/// Works out which language a note is written in, on device.
///
/// Notes too short or too mixed to call return nil, and the filter keeps
/// them: an image post with a two-word caption, or one that is only links
/// and hashtags, has no language to judge, and hiding those would empty the
/// feed of pictures.
enum FeedLanguageDetector {
    /// Letters needed before a guess is trusted. Below this the recognizer
    /// guesses wildly ("gm" reads as Dutch).
    static let minimumLetters = 12
    /// Confidence the top guess needs.
    static let minimumConfidence = 0.6

    /// "en-US" -> "en", "zh-Hant" -> "zh", "pt_BR" -> "pt".
    static func baseCode(_ identifier: String) -> String? {
        let base = identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)?.lowercased()
        guard let base, !base.isEmpty, base != "und" else { return nil }
        return base
    }

    /// The note text with what is not language stripped: links, nostr:
    /// references, hashtags, @mentions.
    static func prose(from content: String) -> String {
        content
            .split(whereSeparator: { $0.isWhitespace })
            .filter { word in
                let w = word.lowercased()
                return !(w.hasPrefix("http://") || w.hasPrefix("https://") || w.hasPrefix("nostr:")
                    || w.hasPrefix("#") || w.hasPrefix("@") || w.hasPrefix("npub1") || w.hasPrefix("note1"))
            }
            .joined(separator: " ")
    }

    /// The words to judge. A repost (kind 6) carries the reposted event as
    /// JSON, so it is judged by that event's text, not by the JSON.
    static func text(of content: String, kind: Int) -> String {
        guard kind == 6 else { return content }
        guard let data = content.data(using: .utf8),
              let inner = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let innerContent = inner["content"] as? String else { return "" }
        return innerContent
    }

    /// ISO 639-1 code of the note's language, or nil when it can't be told.
    static func detect(_ content: String) -> String? {
        let text = prose(from: content)
        guard text.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= minimumLetters else {
            return nil
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= minimumConfidence else { return nil }
        return baseCode(language.rawValue)
    }

    /// Whether a note may show when the feed is narrowed to `allowed`.
    /// An empty `allowed` means no narrowing.
    static func admits(detected: String?, allowed: Set<String>) -> Bool {
        guard !allowed.isEmpty, let detected else { return true }
        return allowed.contains(detected)
    }
}
