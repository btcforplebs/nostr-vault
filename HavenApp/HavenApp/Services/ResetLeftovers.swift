import Foundation
import UserNotifications
#if os(iOS)
import WidgetKit
#endif

/// What a factory reset must clear outside Application Support, so the app
/// afterwards looks like a fresh install: saved key passwords in the
/// keychain, pending and delivered notifications, and on iOS the widget
/// snapshot and thumbnails (shared keychain items the widgets read), and the
/// FIPS mesh key and switches, so the next mesh start has a new npub.
@MainActor
enum ResetLeftovers {
    static func clear() {
        CredentialStore.deleteAll()

        let notifications = UNUserNotificationCenter.current()
        notifications.removeAllPendingNotificationRequests()
        notifications.removeAllDeliveredNotifications()

        #if os(iOS)
        FipsMeshService.shared.stopForReset()
        #elseif os(macOS)
        MacFipsMeshService.shared.stopForReset()
        #endif
        MeshIdentityReset.clear()

        #if os(iOS)
        NVSharedStore.clear()
        NVThumbnailStore.clear()
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
