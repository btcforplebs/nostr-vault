import SwiftUI

/// Today's "Share → Nostr Vault" for photos and videos. The extension still
/// copies the files into NVShareInbox and leaves the same notification; this
/// intent only says it happened, and claiming it starts the same upload the
/// notification tap does. No card, nothing visibly different.
struct UploadShareHandler: SharePortalHandler {
    let action = NVShareAction.upload
    var needsReview: Bool { false }

    func handleOnClaim(_ intent: NVShareIntent) {
        ShareInboxTrigger.open()
    }
}
