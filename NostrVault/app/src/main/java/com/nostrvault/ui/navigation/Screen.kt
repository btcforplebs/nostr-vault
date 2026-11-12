package com.nostrvault.ui.navigation

/**
 * Sealed class route definitions for Jetpack Compose Navigation.
 * Matches the iOS tab/screen structure.
 */
sealed class Screen(val route: String) {
    // Bottom nav tabs
    data object Feed : Screen("feed")
    data object Search : Screen("search")
    /** The Web of Trust globe centred on you (iOS WOTTabView). */
    data object WOT : Screen("wot")
    data object DMInbox : Screen("dm_inbox")
    data object Profile : Screen("profile/{pubkey}") {
        fun createRoute(pubkey: String) = "profile/$pubkey"
    }
    /** A profile's Following / Followers lists, open on [tab]; [total] is the profile's follower count. */
    data object FollowList : Screen("follows/{pubkey}?tab={tab}&total={total}") {
        fun createRoute(pubkey: String, tab: String, total: Int?) =
            "follows/$pubkey?tab=$tab&total=${total ?: -1}"
    }

    // Detail screens
    /** Reader for a NIP-23 long-form post; the note screen renders kind-1 threads. */
    data object ArticleReader : Screen("article/{noteId}") {
        fun createRoute(noteId: String) = "article/$noteId"
    }
    /** A `nostr:naddr1…` link: resolves the address, then opens the article or post. */
    data object AddressLink : Screen("naddr/{naddr}") {
        fun createRoute(naddr: String) = "naddr/$naddr"
    }
    data object NoteDetail : Screen("note/{noteId}") {
        fun createRoute(noteId: String) = "note/$noteId"
    }
    /** Posts tagged with one hashtag (`#t`), live. [tag] is lowercased, no #. */
    data object HashtagFeed : Screen("hashtag/{tag}") {
        fun createRoute(tag: String) = "hashtag/${android.net.Uri.encode(tag)}"
    }
    data object DMThread : Screen("dm_thread/{pubkey}?draft={draft}") {
        /** [draft] is typed into the message box on open (Message seller). */
        fun createRoute(pubkey: String, draft: String? = null) =
            if (draft != null) "dm_thread/$pubkey?draft=${android.net.Uri.encode(draft)}" else "dm_thread/$pubkey"
    }
    data object NewMessage : Screen("new_message?pubkey={pubkey}") {
        fun createRoute(pubkey: String? = null) =
            if (pubkey != null) "new_message?pubkey=$pubkey" else "new_message"
    }
    data object ComposeNote : Screen("compose?replyTo={replyTo}&quoteTo={quoteTo}&draftId={draftId}&text={text}") {
        fun createRoute(
            replyToNoteId: String? = null,
            quoteToNoteId: String? = null,
            draftId: String? = null,
            /** Prefilled text (Share a song to Nostr). */
            text: String? = null,
        ): String {
            val params = mutableListOf<String>()
            replyToNoteId?.let { params.add("replyTo=$it") }
            quoteToNoteId?.let { params.add("quoteTo=$it") }
            draftId?.let { params.add("draftId=$it") }
            text?.let { params.add("text=${android.net.Uri.encode(it)}") }
            return if (params.isNotEmpty()) "compose?${params.joinToString("&")}" else "compose"
        }
    }
    /** diVine, article or recipe composer; [kind] is a ModeComposerKind route. */
    data object ModeCompose : Screen("compose_mode/{kind}?draft={draft}") {
        /** [draft]: a saved draft to open (the share portal's article clip / recipe). */
        fun createRoute(kind: String, draft: String? = null) =
            if (draft == null) "compose_mode/$kind" else "compose_mode/$kind?draft=${android.net.Uri.encode(draft)}"
    }
    data object Drafts : Screen("drafts")

    // Wallet
    data object Wallet : Screen("wallet")
    data object WalletSettings : Screen("settings/wallet")
    data object BitcoinSweep : Screen("bitcoin_sweep")
    data object BitcoinWallet : Screen("settings/bitcoin")

    // Settings
    data object Settings : Screen("settings")
    data object AppearanceSettings : Screen("settings/appearance")
    data object FeedSettings : Screen("settings/feed")
    data object TutorialsSettings : Screen("settings/tutorials")
    data object AccountSettings : Screen("settings/accounts")
    data object BlockedSettings : Screen("settings/blocked")
    data object RecentlyDeletedSettings : Screen("settings/recently-deleted")
    data object Relays : Screen("settings/relays")
    data object BlossomSettings : Screen("settings/blossom")
    data object PowSettings : Screen("settings/pow")
    data object AdvancedSettings : Screen("settings/advanced")
    data object MediaSettings : Screen("settings/media")
    data object PrivacySettings : Screen("settings/privacy")
    data object RelayAccessSettings : Screen("settings/relay_access")
    data object ImportSettings : Screen("settings/import")
    data object BackupSettings : Screen("settings/backup")
    data object FollowingBackup : Screen("settings/following_backup")
    data object ListBackup : Screen("settings/list_backup")
    data object NotificationSettings : Screen("settings/notifications")
    data object HavenRelaySettings : Screen("settings/haven_relay")
    /** Settings › Your Devices: your devices, the two-scan link, this phone as a vault; Mesh and by-address under Advanced. */
    data object YourDevices : Screen("settings/your_devices")
    /** Settings → Mesh → FIPS Mesh, and its device and Advanced pages. */
    data object MeshSettings : Screen("settings/mesh")
    data object FipsMeshDevice : Screen("settings/mesh/device/{npub}") {
        fun createRoute(npub: String) = "settings/mesh/device/$npub"
    }
    data object FipsMeshAdvanced : Screen("settings/mesh/advanced")
    /** Vault Dashboard › Your devices › Add a device: the two-scan link. */
    data object PairDevice : Screen("vault/pair_device")

    // Dashboard
    /**
     * The Vault tab: the relay's lists and the Blossom gallery in one, the
     * half picked by [VaultSection]. The route keeps the old Relay tab's name.
     */
    data object Dashboard : Screen("dashboard")
    /** The feed dashboard: your follows' last 24 hours (feed menu > Dashboard). */
    data object FeedDashboard : Screen("feed_dashboard")
    data object LogViewer : Screen("log_viewer")
    data object RelayActivity : Screen("relay_activity")

    /** Review card for what another app shared (`nostrvault://shareportal`). */
    data object SharePortalReview : Screen("share_portal")

    // Setup
    data object SetupWizard : Screen("setup")

    // Media viewer
    data object MediaViewer : Screen("media_viewer/{index}") {
        fun createRoute(index: Int) = "media_viewer/$index"
    }
}
