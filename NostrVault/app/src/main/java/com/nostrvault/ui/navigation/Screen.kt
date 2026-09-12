package com.nostrvault.ui.navigation

/**
 * Sealed class route definitions for Jetpack Compose Navigation.
 * Matches the iOS tab/screen structure.
 */
sealed class Screen(val route: String) {
    // Bottom nav tabs
    data object Feed : Screen("feed")
    data object Search : Screen("search")
    data object MediaGallery : Screen("media")
    data object DMInbox : Screen("dm_inbox")
    data object Profile : Screen("profile/{pubkey}") {
        fun createRoute(pubkey: String) = "profile/$pubkey"
    }

    // Detail screens
    /** Reader for a NIP-23 long-form post; the note screen renders kind-1 threads. */
    data object ArticleReader : Screen("article/{noteId}") {
        fun createRoute(noteId: String) = "article/$noteId"
    }
    data object NoteDetail : Screen("note/{noteId}") {
        fun createRoute(noteId: String) = "note/$noteId"
    }
    data object DMThread : Screen("dm_thread/{pubkey}") {
        fun createRoute(pubkey: String) = "dm_thread/$pubkey"
    }
    data object NewMessage : Screen("new_message?pubkey={pubkey}") {
        fun createRoute(pubkey: String? = null) =
            if (pubkey != null) "new_message?pubkey=$pubkey" else "new_message"
    }
    data object ComposeNote : Screen("compose?replyTo={replyTo}&quoteTo={quoteTo}&draftId={draftId}") {
        fun createRoute(
            replyToNoteId: String? = null,
            quoteToNoteId: String? = null,
            draftId: String? = null,
        ): String {
            val params = mutableListOf<String>()
            replyToNoteId?.let { params.add("replyTo=$it") }
            quoteToNoteId?.let { params.add("quoteTo=$it") }
            draftId?.let { params.add("draftId=$it") }
            return if (params.isNotEmpty()) "compose?${params.joinToString("&")}" else "compose"
        }
    }
    data object ProfileEdit : Screen("profile_edit")
    data object Drafts : Screen("drafts")

    // Groups
    data object GroupList : Screen("groups")
    data object GroupChat : Screen("group_chat/{groupId}/{relayUrl}") {
        fun createRoute(groupId: String, relayUrl: String) = "group_chat/$groupId/$relayUrl"
    }
    data object GroupInfo : Screen("group_info/{groupId}/{relayUrl}") {
        fun createRoute(groupId: String, relayUrl: String) = "group_info/$groupId/$relayUrl"
    }
    data object GroupBrowser : Screen("group_browser")
    data object GroupCreate : Screen("group_create")

    // Wallet
    data object Wallet : Screen("wallet")
    data object BitcoinSweep : Screen("bitcoin_sweep")

    // Settings
    data object Settings : Screen("settings")
    data object AppearanceSettings : Screen("settings/appearance")
    data object AccountSettings : Screen("settings/accounts")
    data object BlockedSettings : Screen("settings/blocked")
    data object RelayListEditor : Screen("settings/relays")
    data object BlastrSettings : Screen("settings/blastr")
    data object BlossomSettings : Screen("settings/blossom")
    data object PowSettings : Screen("settings/pow")
    data object AdvancedSettings : Screen("settings/advanced")
    data object ImportSettings : Screen("settings/import")
    data object BackupSettings : Screen("settings/backup")
    data object FollowingBackup : Screen("settings/following_backup")
    data object NotificationSettings : Screen("settings/notifications")
    data object HavenRelaySettings : Screen("settings/haven_relay")
    data object MeshSettings : Screen("settings/mesh")

    // Dashboard
    data object Dashboard : Screen("dashboard")
    data object BlossomDashboard : Screen("blossom_dashboard")
    data object LogViewer : Screen("log_viewer")

    // Setup
    data object SetupWizard : Screen("setup")

    // Media viewer
    data object MediaViewer : Screen("media_viewer/{index}") {
        fun createRoute(index: Int) = "media_viewer/$index"
    }
}
