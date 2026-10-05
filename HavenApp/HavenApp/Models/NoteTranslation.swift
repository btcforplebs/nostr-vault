import Foundation

/// Rules for the Translate button on posts. Pure, so it is unit tested; the
/// button itself lives in NoteTranslateButton.
enum NoteTranslation {
    /// The language posts are translated into: the one chosen in Settings, or
    /// the device's own language when none is chosen.
    static func targetCode(setting: String, preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        if let chosen = FeedLanguageDetector.baseCode(setting) { return chosen }
        return preferredLanguages.lazy.compactMap { FeedLanguageDetector.baseCode($0) }.first ?? "en"
    }

    /// Offer a translation only when the post's language is known and is not
    /// the target. Unknown (too short, only links) gets no button.
    static func shouldOffer(detected: String?, target: String) -> Bool {
        guard let detected else { return false }
        return detected != target
    }

    /// The words worth translating: links and nostr: references stay out (the
    /// post shows them as cards), the rest — hashtags and mentions included —
    /// goes in so the translation reads like the post.
    static func translatableText(_ content: String) -> String {
        content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.split(separator: " ", omittingEmptySubsequences: false)
                    .filter { word in
                        let w = word.lowercased()
                        return !(w.hasPrefix("http://") || w.hasPrefix("https://") || w.hasPrefix("nostr:"))
                    }
                    .joined(separator: " ")
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
