import SwiftUI

/// "Open in zap.cooking" and friends: a menu item that hands the content to
/// the system browser. Every screen uses this one, so the wording and the
/// icon are the same wherever it shows up.
struct OpenInWebButton: View {
    let link: NostrWebLink

    var body: some View {
        Button {
            PlatformURL.open(link.url)
        } label: {
            Label("Open in \(link.siteName)", systemImage: "safari")
        }
    }
}

extension FeedNote {
    /// Where this post opens on the web, when it is a kind that has a place
    /// there (articles and recipes today).
    var webLink: NostrWebLink? {
        NostrWebLink.longForm(kind: kind, pubkey: pubkey, tags: tags)
    }
}

extension View {
    /// Long-press (right-click on the Mac) offers "Open in …" for a card.
    @ViewBuilder
    func openInWebContextMenu(_ link: NostrWebLink?) -> some View {
        if let link {
            contextMenu { OpenInWebButton(link: link) }
        } else {
            self
        }
    }
}

extension LiveStream {
    var webLink: NostrWebLink? {
        NostrWebLink.liveStream(authorPubkey: authorPubkey, identifier: identifier, relays: chatRelays)
    }
}
