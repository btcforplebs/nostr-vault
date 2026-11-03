import Foundation

/// Opens the Media tab and uploads what the share sheet left in the App Group
/// inbox (NVShareInbox). Used by the `nostrvault://shareinbox` link and by the
/// Share Portal's `upload` action, so both take the same path.
@MainActor
enum ShareInboxTrigger {
    static func open() {
        let center = NotificationCenter.default
        center.post(name: .havenOpenMedia, object: nil)
        // Same beat as Magic Paste: the gallery has to be listening.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            center.post(name: .havenImportShareInbox, object: nil)
        }
    }
}
