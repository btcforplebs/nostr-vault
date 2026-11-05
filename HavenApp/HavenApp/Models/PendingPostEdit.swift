import Foundation

/// What Edit on a pending post hands back to the composer.
///
/// The composer publishes its text plus, for a quote, `\nnostr:<nevent>` of
/// the quoted note, and each hosted photo as a link with an `imeta` tag. Edit
/// used to hand the published text back as it was, so the composer, which
/// adds the quote line again on Post, posted it twice, and the photos came
/// back as bare links with no attachment behind them.
enum PendingPostEdit {
    /// On the Mac the reopened composer is Feed's, and the countdown pill
    /// is on every tab: an Edit tapped elsewhere goes to Feed first (it used
    /// to cancel the post and open nothing).
    static func switchesToFeed(hasRequest: Bool, onFeed: Bool) -> Bool {
        hasRequest && !onFeed
    }

    /// A hosted photo or video from the pending post's `imeta` tags.
    struct Media: Equatable {
        let url: String
        let mimeType: String?
        let alt: String?
    }

    /// The text to edit: the published text without the quote line the
    /// composer adds itself. Only a trailing line is taken off, so the same
    /// reference typed into the body stays.
    static func editableText(_ published: String, quotedNevent: String?) -> String {
        guard let quotedNevent, !quotedNevent.isEmpty else { return published }
        let suffix = "\nnostr:\(quotedNevent)"
        guard published.hasSuffix(suffix) else { return published }
        return String(published.dropLast(suffix.count))
    }

    /// The hosted media to bring back as attachments: each NIP-92 `imeta`
    /// with a `url` that is still in the text, in tag order, once each.
    static func media(fromTags tags: [[String]], in text: String) -> [Media] {
        var seen = Set<String>()
        var out: [Media] = []
        for tag in tags where tag.first == "imeta" {
            var fields: [String: String] = [:]
            for entry in tag.dropFirst() {
                guard let space = entry.firstIndex(of: " ") else { continue }
                let key = String(entry[..<space])
                if fields[key] == nil { fields[key] = String(entry[entry.index(after: space)...]) }
            }
            guard let url = fields["url"], !url.isEmpty, text.contains(url), seen.insert(url).inserted else { continue }
            let alt = fields["alt"].flatMap { $0.isEmpty ? nil : $0 }
            out.append(Media(url: url, mimeType: fields["m"], alt: alt))
        }
        return out
    }
}
