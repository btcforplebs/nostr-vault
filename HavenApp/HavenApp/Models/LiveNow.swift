import Foundation

/// Your space's Live now panel: the streams (NIP-53 kind 30311) of people
/// you follow that are on air right now, newest first. The same rules as the
/// Live tab's Following: the newest event per stream address wins (an ended
/// stream replaces its own live announcement), the author or the `p` tag
/// marked Host must be followed, a block on either hides it, and only a
/// stream that is on air with an HLS URL the player can open counts.
/// The web's twin is `web-vault/src/desktop/space/live-now.js`.
///
/// Pure Foundation so MediaLogicTests covers it; `LiveNowModel` fetches.
enum LiveNow {
    /// The panel's id in the synced layout, shared with the web. Never rename.
    static let panelId = "live-now"
    /// Rows drawn; the rest are a "+N more" line to the Live tab.
    static let maxRows = 5
    /// How often an open panel asks again: streams start at any time.
    static let refreshEvery: TimeInterval = 2 * 60

    static func pick(_ events: [LiveStatusBook.Event], follows: Set<String>, blocked: Set<String>,
                     now: Int64) -> [LiveStatusBook.Event] {
        var newest: [String: LiveStatusBook.Event] = [:]
        for event in events {
            guard let address = event.address else { continue }
            if let have = newest[address], have.createdAt >= event.createdAt { continue }
            newest[address] = event
        }
        return newest.values
            .filter { event in
                !blocked.contains(event.pubkey) && !blocked.contains(event.host)
                    && LiveChat.isFollowed(authorPubkey: event.pubkey, tags: event.tags, follows: follows)
                    && event.isLive(at: now)
            }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return ($0.address ?? "") > ($1.address ?? "")
            }
    }

    /// The calm line drawn when nobody is live.
    static func emptyLine(followsSomeone: Bool) -> String {
        followsSomeone ? "Nobody you follow is live right now." : "Follow people to see when they go live."
    }
}
