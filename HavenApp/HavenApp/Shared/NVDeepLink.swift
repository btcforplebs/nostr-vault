import Foundation

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
    /// Media tab, uploading what the share sheet queued (NVShareInbox). The
    /// share extension's "ready to upload" notification carries this link.
    case shareInbox = "shareinbox"
    /// Review what the Share Portal queued (NVShareQueue): a highlight, a
    /// link, later a payment. The portal's notification carries this link.
    case sharePortal = "shareportal"
    case wallet

    var url: URL { URL(string: "nostrvault://\(rawValue)")! }

    /// `nostrvault://note/<hex id>`: opens one note (On this day widget).
    /// Not `nostr:`, which another installed client could claim.
    static func noteURL(_ id: String) -> URL? {
        guard isEventID(id) else { return nil }
        return URL(string: "nostrvault://note/\(id.lowercased())")
    }

    /// The hex event id in a `nostrvault://note/<id>` link, or nil.
    static func noteID(from url: URL) -> String? {
        guard url.scheme == "nostrvault" else { return nil }
        var parts = url.path.split(separator: "/").map(String.init)
        if let host = url.host, !host.isEmpty { parts.insert(host, at: 0) }
        guard parts.count == 2, parts[0] == "note", isEventID(parts[1]) else { return nil }
        return parts[1].lowercased()
    }

    private static func isEventID(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { $0.isHexDigit }
    }

    init?(url: URL) {
        guard url.scheme == "nostrvault" else { return nil }
        // nostrvault://feed  -> host "feed"
        // nostrvault:///feed -> path "/feed"
        let token = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.init(rawValue: token)
    }
}
