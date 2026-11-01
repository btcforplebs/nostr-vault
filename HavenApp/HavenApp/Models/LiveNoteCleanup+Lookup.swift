import Foundation

extension LiveNoteCleanup {
    /// `content` and `mediaURLs` with the links of any live stream the text
    /// embeds taken out (`clean`). `find` resolves the embedded stream events
    /// for their own picture and playlist links; a stream not loaded yet still
    /// loses its `.m3u8`. Nil when the text embeds no live stream, so callers
    /// keep what they had.
    ///
    /// Before this only the expanded feed card cleaned its body, and an old
    /// "Share as a note" live post drew a bare `.m3u8` link in the condensed
    /// row, thread cards, note detail and Vault rows (sweep 11-01 #4).
    static func cleaned(content: String, mediaURLs: [URL], linkURLs: [URL] = [],
                        find: (String) -> FeedNote?) -> Body? {
        let liveIds = liveQuoteIds(in: content)
        guard !liveIds.isEmpty else { return nil }
        let urls = liveIds.compactMap(find).reduce(into: Set<String>()) {
            $0.formUnion(streamURLs(tags: $1.tags))
        }
        return clean(Body(content: content, mediaURLs: mediaURLs, linkURLs: linkURLs), streamURLs: urls)
    }
}
