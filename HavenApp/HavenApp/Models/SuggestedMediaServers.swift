import Foundation

/// A Blossom server offered under Media Servers › Suggested, so people can add
/// one with a tap instead of knowing an address.
struct SuggestedMediaServer: Equatable, Identifiable {
    let url: String
    /// One plain line: free or paid, and the limit that matters.
    let note: String

    var id: String { url }
    var host: String { URLComponents(string: url)?.host ?? url }
}

enum SuggestedMediaServers {
    /// Checked live on 2026-10-28: each answers, keeps files, and the free
    /// ones take uploads from any npub. Left out on purpose: nostr.download and 24242.io
    /// delete files nobody opens, which is wrong for a vault. Prices and limits
    /// drift, so re-check this list before a release.
    /// Android: `SuggestedMediaServers.kt`; web: `suggested-servers.js`.
    static let all: [SuggestedMediaServer] = [
        SuggestedMediaServer(url: "https://blossom.primal.net", note: "Free"),
        SuggestedMediaServer(url: "https://blossom.nostr.build", note: "Free up to 20 MB a file · paid plans from $18 a year"),
        SuggestedMediaServer(url: "https://nostr.media", note: "Free"),
        SuggestedMediaServer(url: "https://blossom.azzamo.media", note: "Free tier · paid from $3 a month"),
        SuggestedMediaServer(url: "https://blossom.jumble.social", note: "Free up to 20 MB a file"),
        SuggestedMediaServer(url: "https://nostrmedia.com", note: "Paid only · from $2.99 a month"),
    ]

    /// The suggestions not already in `servers`. A server counts as added when
    /// it uploads to the same place, so a typed `nostr.build` hides
    /// `blossom.nostr.build`.
    static func notYetAdded(_ servers: [String]) -> [SuggestedMediaServer] {
        let added = Set(servers.compactMap(uploadHost))
        return all.filter { !added.contains($0.host) }
    }

    private static func uploadHost(_ server: String) -> String? {
        guard let target = HavenConfig.blossomUploadServer(server) else { return nil }
        let withScheme = target.contains("://") ? target : "https://" + target
        return URLComponents(string: withScheme)?.host?.lowercased()
    }
}
