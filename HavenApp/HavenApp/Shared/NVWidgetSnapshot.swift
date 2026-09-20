import Foundation

// MARK: - Widget Snapshot
//
// Widgets run in their own process and cannot reach the app's services, its
// relay, or its database. Everything a widget draws therefore has to be handed
// across a process boundary ahead of time.
//
// The usual vehicle is an App Group container, which this project cannot use:
// registering that capability needs an Apple ID signed into Xcode and there is
// none on this machine (see NVSharedStore for the whole story). What both
// processes *do* share is a keychain access group, granted by the wildcard
// provisioning profile. So the app writes one small Codable snapshot there and
// the widgets read it.
//
// That constraint sets the shape of everything below: keep it small, keep it
// flat, and store text and URLs rather than images. Widgets can fetch an avatar
// themselves and WidgetKit caches it; a keychain item is the wrong place for
// image bytes.

/// Everything the widgets can draw, as of `generatedAt`.
struct NVWidgetSnapshot: Codable, Equatable {
    var generatedAt: Date
    var relay: Relay
    var feed: [Note]
    var mentions: [Note]
    var wallet: Wallet
    var media: [MediaTile]
    var unreadDMCount: Int

    static let empty = NVWidgetSnapshot(
        generatedAt: .distantPast,
        relay: Relay(isRunning: false, eventCount: 0, storageBytes: 0, connectionCount: 0, uptimeSeconds: 0),
        feed: [],
        mentions: [],
        wallet: Wallet(lightningSats: nil, zapsReceived24h: 0, btcPriceUSD: nil),
        media: [],
        unreadDMCount: 0
    )

    struct Relay: Codable, Equatable {
        var isRunning: Bool
        var eventCount: Int
        var storageBytes: Int64
        var connectionCount: Int
        var uptimeSeconds: Int
    }

    /// A note flattened for display. No parsing, no media resolution, no
    /// threading -- the widget has no budget for any of it.
    struct Note: Codable, Equatable, Identifiable {
        var id: String
        var authorName: String
        var authorPictureURL: URL?
        var text: String
        var createdAt: Date
        /// First image in the note, if any, for layouts that show one.
        var imageURL: URL?
    }

    struct Wallet: Codable, Equatable {
        var lightningSats: Int?
        var zapsReceived24h: Int
        var btcPriceUSD: Double?
    }

    struct MediaTile: Codable, Equatable, Identifiable {
        var id: String
        var url: URL
        /// Optional so a snapshot written by an older build still decodes: a
        /// tile with no kind shows under "All" and nowhere narrower.
        var kind: NVMediaKind?
    }
}

// MARK: - Deep Links

/// Destinations a widget tap can request. The app registers `nostrvault://`
/// and routes these so a tap lands on the right screen instead of just
/// reopening whatever was last on top.
enum NVDeepLink: String {
    case feed
    case mentions
    case compose
    case dms
    case search
    case relay
    case media
    /// Media tab with the app's Magic Paste already running. A widget cannot
    /// read the clipboard itself, so the tap lands here instead.
    case mediaPaste = "mediapaste"
    case wallet

    var url: URL { URL(string: "nostrvault://\(rawValue)")! }

    init?(url: URL) {
        guard url.scheme == "nostrvault" else { return nil }
        // nostrvault://feed  -> host "feed"
        // nostrvault:///feed -> path "/feed"
        let token = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.init(rawValue: token)
    }
}
