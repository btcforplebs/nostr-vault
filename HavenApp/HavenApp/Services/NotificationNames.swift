import Foundation

extension Notification.Name {
    /// Posted after the media cache is cleared, so open views re-read where each file lives.
    static let havenMediaCacheCleared = Notification.Name("com.haven.mediaCacheCleared")
    /// Posted after a delete request for your own posts; `object` is the
    /// set of event ids, so views holding their own copy of a post drop it.
    static let havenOwnEventsDeleted = Notification.Name("com.haven.ownEventsDeleted")
    /// Posted when the user taps a push notification about a relay event — navigates to Viewer tab.
    static let havenOpenViewer = Notification.Name("com.haven.openViewer")
    /// Posted when the user taps a push notification about a following feed note — navigates to Feed tab.
    static let havenOpenFeed   = Notification.Name("com.haven.openFeed")
    /// Posted when the user taps a DM notification — opens the DM inbox.
    static let havenOpenDMInbox = Notification.Name("OpenDMInbox")
    /// Posted when the user taps a mention/reply notification — opens the note detail.
    static let havenOpenMentions = Notification.Name("OpenMentions")
    /// Posted when the user taps a zap notification — opens relay page zaps section.
    static let havenOpenRelayZaps = Notification.Name("com.haven.openRelayZaps")
    /// Posted to navigate to wallet.
    static let havenOpenWallet = Notification.Name("OpenWallet")
    /// Posted when the user taps a reaction notification — opens relay page likes section.
    static let havenOpenRelayLikes = Notification.Name("com.haven.openRelayLikes")
    /// Posted when the user taps a new-follower notification — switches the
    /// relay page to its Followers list (the profile opens via havenOpenProfile).
    static let havenOpenRelayFollowers = Notification.Name("com.haven.openRelayFollowers")
    /// Switches the Vault tab to its first list, "Vault": everything new.
    static let havenOpenRelayActivity = Notification.Name("com.haven.openRelayActivity")
    /// Posted when the user taps a repost notification — opens relay page notes section.
    static let havenOpenRelayNotes = Notification.Name("com.haven.openRelayNotes")
    /// Posted after a relay-tab route when a notification names one event — the
    /// relay tab scrolls to it. The target itself is parked in `RelayFocus.pending`.
    static let havenFocusRelayEvent = Notification.Name("com.haven.focusRelayEvent")
    /// Posted after `havenOpenFeed` when a tapped notification has a post to
    /// open. The post itself is parked in `NotificationOpen.pending`.
    static let havenOpenNotificationNote = Notification.Name("com.haven.openNotificationNote")
    /// Posted when the user taps feed relays in the dashboard — navigates to Settings > Feed Relays.
    static let havenOpenFeedRelaySettings = Notification.Name("com.haven.openFeedRelaySettings")
    /// Posted to open the Settings view from any context (e.g. profile toolbar, footer gear).
    static let havenOpenSettings = Notification.Name("com.haven.openSettings")
    /// Posted by FeedView when scroll direction changes — object is Bool (true = scrolling down = collapse tab bar).
    static let feedScrollDirectionChanged = Notification.Name("com.haven.feedScrollDirectionChanged")
    /// Posted by the collapsed tab bar to trigger compose in the active tab.
    static let composeFromTabBar = Notification.Name("com.haven.composeFromTabBar")
    /// Posted by the collapsed tab bar (or menu bar) to open the relay dashboard.
    static let openRelayDashboard = Notification.Name("com.haven.openRelayDashboard")
    /// Posted by the collapsed tab bar on the Media tab to open the Blossom dashboard.
    static let openBlossomDashboard = Notification.Name("com.haven.openBlossomDashboard")

    /// Widget deep links. Search and Media had no existing route because
    /// nothing else needed to open them programmatically.
    static let havenOpenSearch = Notification.Name("com.haven.openSearch")
    /// ⌘F on an iPad keyboard: the Search tab's field takes the keystrokes.
    /// Posted after the switch to the Search tab.
    static let havenFocusSearch = Notification.Name("com.haven.focusSearch")
    /// ⌘R on an iPad keyboard: refresh what the tab is showing. `object` is
    /// the tab's index (Int), so only the showing tab's view acts on it.
    static let havenRefreshTab = Notification.Name("com.haven.refreshTab")
    static let havenOpenMedia = Notification.Name("com.haven.openMedia")
    /// The WOT tab was tapped while showing: its globe goes back to you.
    static let wotTabReselected = Notification.Name("com.haven.wotTabReselected")
    /// Run the Media tab's Magic Paste. Posted after `havenOpenMedia` when the
    /// Mosaic widget's wand is tapped, so one tap gets the same result as
    /// Media tab -> + -> Magic Paste.
    static let havenMagicPaste = Notification.Name("com.haven.magicPaste")
    /// Upload what the share sheet left in the App Group inbox (NVShareInbox).
    /// Posted after `havenOpenMedia` by the share notification and app launch.
    static let havenImportShareInbox = Notification.Name("com.haven.importShareInbox")

    /// A `nostr:` link opened from outside the app. `object` is the hex pubkey
    /// (`havenOpenProfile`), or the hex event id / `naddr1…` (`havenOpenNote`).
    static let havenOpenProfile = Notification.Name("com.haven.openProfile")
    static let havenOpenNote = Notification.Name("com.haven.openNote")
}
