import Foundation

/// What a live stream is shared as: its nostrvault.app address for Copy link
/// and the share sheet, and the text of a kind 1 note announcing it.
///
/// Kept free of SwiftUI so `MediaLogicTests` can compile it.
enum LiveStreamShare {
    /// The stream's `naddr`, addressed by who signed the event (a service
    /// such as zap.stream signs for the host), with its own relays as hints.
    static func naddr(authorPubkey: String, identifier: String, relays: [String]) -> String? {
        NostrWebLink.naddr(kind: NostrWebLink.liveStreamKind, pubkey: authorPubkey,
                           identifier: identifier, relays: relays)
    }

    /// https://nostrvault.app/thread/<naddr>: the public post page reads an
    /// naddr as well as a nevent, so a stream shares like any post.
    static func link(naddr: String) -> URL? {
        URL(string: "\(ProfileShareLink.site)/thread/\(naddr)")
    }

    /// The note "Share as a note" starts the composer with: who is live, then
    /// the stream's `nostr:naddr1…`, which every NIP-53 client draws as the
    /// stream's own card with its current title and picture. No title in the
    /// text: a host such as The Lot Radio republishes one 30311 for every
    /// show, so a title written now names the wrong show an hour later. No
    /// picture or `.m3u8` link either: next to the card they drew the same
    /// picture twice and a bare stream link (Logen, 2026-10-31).
    static func noteText(hostName: String, naddr: String?) -> String {
        let heading = "Live now: \(hostName)"
        guard let naddr else { return heading }
        return "\(heading)\n\nnostr:\(naddr)"
    }

    /// NIP-18 `q` tags for the live streams a note's text embeds: one
    /// `["q", "30311:<pubkey>:<d>", relayHint]` per stream, repeats dropped, so
    /// clients that read tags rather than text still know what is quoted.
    static func quoteTags(in content: String, relayHint: String = "") -> [[String]] {
        LiveNoteCleanup.liveCoordinates(in: content).map { coordinate in
            ["q", "\(NostrWebLink.liveStreamKind):\(coordinate.pubkey):\(coordinate.dTag)", relayHint]
        }
    }
}
