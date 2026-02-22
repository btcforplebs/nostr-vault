import Foundation

extension Notification.Name {
    /// Posted when the user taps a push notification about a relay event — navigates to Viewer tab.
    static let havenOpenViewer = Notification.Name("com.haven.openViewer")
    /// Posted when the user taps a push notification about a following feed note — navigates to Feed tab.
    static let havenOpenFeed   = Notification.Name("com.haven.openFeed")
}
