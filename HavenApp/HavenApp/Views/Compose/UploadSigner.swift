import Foundation

/// Which account signed an attachment's upload, so Post never publishes a
/// link that another account put up.
///
/// Uploads start when a photo is picked, and the BUD-02 authorisation is
/// signed by whichever account is active at that moment. The account can
/// change before Post (the composer's avatar menu, the switcher, a
/// notification tap). Posting account B's note with a link account A uploaded
/// would tie A to B at the Blossom server, which is what
/// `BlossomService.makeUploadAuth` exists to prevent, and would put the blob
/// on A's servers instead of B's.
enum UploadSigner {
    /// Recorded when the account changed while the upload ran: matches no
    /// account, so Post always uploads it again.
    static let changedDuringUpload = "changed-during-upload"

    /// The signer to record for an upload, given the active account when it
    /// began and when it finished.
    static func recorded(atStart: String, atEnd: String) -> String {
        atStart == atEnd ? atStart : changedDuringUpload
    }

    /// Whether Post must upload the attachment again under `lockedHex`.
    /// `signer` is nil when nothing was signed for it (media picked from
    /// this device's relay, or an upload that never ran).
    static func needsReupload(signer: String?, lockedHex: String) -> Bool {
        guard let signer else { return false }
        return signer != lockedHex
    }
}
