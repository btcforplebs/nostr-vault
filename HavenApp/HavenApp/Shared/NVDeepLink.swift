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

    init?(url: URL) {
        guard url.scheme == "nostrvault" else { return nil }
        // nostrvault://feed  -> host "feed"
        // nostrvault:///feed -> path "/feed"
        let token = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.init(rawValue: token)
    }
}
