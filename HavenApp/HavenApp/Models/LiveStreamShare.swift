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

    /// A kind 1 that other apps can play. Most clients draw a bare `.m3u8`
    /// link as a video and a bare picture link as a picture, while the
    /// `nostr:naddr1…` quote lets NIP-53 clients open the stream itself with
    /// its chat. One item per line, so each link stands alone for a parser.
    static func noteText(title: String?, hostName: String, pictureURL: URL?,
                         streamingURL: URL?, naddr: String?) -> String {
        let heading = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = []
        if let heading, !heading.isEmpty {
            lines.append("\(heading), live now with \(hostName)")
        } else {
            lines.append("\(hostName) is live now")
        }
        var links: [String] = []
        if let pictureURL { links.append(pictureURL.absoluteString) }
        if let streamingURL { links.append(streamingURL.absoluteString) }
        if let naddr { links.append("nostr:\(naddr)") }
        if !links.isEmpty { lines.append("") }
        return (lines + links).joined(separator: "\n")
    }
}
