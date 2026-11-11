import Foundation

// Stand-ins for the app-target pieces FeedServiceTypes.swift and
// FeedFilterEngine.swift reach (RepostTrustTests).

/// The app's media fetcher (Services/MediaCache/BlossomURIFetch.swift) needs
/// the network stack; the feed only registers URLs with it.
enum BlossomURIFetcher {
    static func register(_ urls: [URL], author: String) {}
}

extension FeedNote {
    /// Same as the app's (Views/Components/PollCardView.swift), which lives in a view file.
    var poll: NIP88Poll.Poll? {
        NIP88Poll.Poll(id: id, pubkey: pubkey, kind: kind, content: content, tags: tags)
    }
}
