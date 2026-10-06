package com.nostrvault.ui.navigation

/**
 * Where a tap from outside the app should land.
 *
 * @param route a nav route from [Screen].
 * @param accountNpub the account the thing belongs to, when the caller knew it
 *   (notifications do). The consumer switches to it before navigating, so a
 *   mention of your second identity does not open under the first.
 */
data class DeepLinkTarget(
    val route: String,
    val accountNpub: String? = null,
    /** Set when the route is the Relay tab and it should scroll to one event. */
    val relayFocus: RelayFocusRequest? = null,
    /** Paste the clipboard into Blossom once the Media tab shows (`nostrvault://mediapaste`). */
    val mediaPaste: Boolean = false,
)

/**
 * bech32 decoding, injected rather than called directly, so [DeepLinkRouter]
 * stays a plain JVM unit that unit tests can drive. The real implementation is
 * HavenBridge, which needs the native library loaded.
 */
interface NostrEntityDecoder {
    fun noteToHex(note1: String): String?
    fun neventToHex(nevent1: String): String?
    fun npubToHex(npub: String): String?
    fun nprofileToHex(nprofile: String): String?
}

/**
 * Turns `nostrvault://…` links, `nostr:…` links and notification payloads into
 * a route.
 *
 * Everything outside the app that wants to open something inside it comes
 * through here: widgets (every widget tap is a `nostrvault://` link, matching
 * iOS's NVWidgetBridge), a `nostr:` link handed over by another app, and the
 * extras a notification's PendingIntent carries. One router, so a new entry
 * point cannot invent its own half of the mapping.
 */
object DeepLinkRouter {

    /**
     * @return the destination, or null if the link is not one we serve — the
     *   caller should then leave the app wherever it was rather than guess.
     */
    fun fromUri(raw: String, decoder: NostrEntityDecoder): DeepLinkTarget? {
        val uri = raw.trim()
        return when {
            uri.startsWith("nostrvault://", ignoreCase = true) ->
                fromAppLink(uri.removePrefix("nostrvault://").removePrefix("NOSTRVAULT://"), decoder)
            uri.startsWith("nostr:", ignoreCase = true) ->
                fromEntity(uri.substring("nostr:".length), decoder)
            // A bare entity, e.g. text shared from another app.
            else -> fromEntity(uri, decoder)
        }
    }

    private fun fromAppLink(body: String, decoder: NostrEntityDecoder): DeepLinkTarget? {
        val path = body.trim('/')
        if (path.isEmpty()) return DeepLinkTarget(Screen.Feed.route)
        val segments = path.split('/')
        return when (segments[0].lowercase()) {
            "feed" -> DeepLinkTarget(Screen.Feed.route)
            // Android has no mentions surface of its own yet; iOS's mentions tab
            // has no counterpart here, and the feed is the honest nearest thing.
            // A notification about a specific mention does better than this — it
            // carries the event id and opens the note.
            "mentions" -> DeepLinkTarget(Screen.Feed.route)
            "compose" -> DeepLinkTarget(Screen.ComposeNote.createRoute())
            // iOS opens the Media tab and pastes the clipboard into Blossom.
            "mediapaste" -> DeepLinkTarget(Screen.MediaGallery.route, mediaPaste = true)
            "dms" -> DeepLinkTarget(Screen.DMInbox.route)
            "search" -> DeepLinkTarget(Screen.Search.route)
            "relay" -> DeepLinkTarget(Screen.Dashboard.route)
            "media" -> DeepLinkTarget(Screen.MediaGallery.route)
            "wallet" -> DeepLinkTarget(Screen.Wallet.route)
            "note" -> segments.getOrNull(1)?.let { noteRoute(it, decoder) }
            "profile" -> segments.getOrNull(1)?.let { profileRoute(it, decoder) }
            else -> null
        }
    }

    private fun fromEntity(entity: String, decoder: NostrEntityDecoder): DeepLinkTarget? {
        val e = entity.trim().removePrefix("nostr:").substringBefore('?')
        return when {
            e.startsWith("note1") || e.startsWith("nevent1") -> noteRoute(e, decoder)
            e.startsWith("npub1") || e.startsWith("nprofile1") -> profileRoute(e, decoder)
            // naddr names an addressable event by kind/author/"d" tag, not by
            // id, and every route here takes an id. Resolving one means asking
            // a relay for it first, which a pure router cannot do — so it
            // returns null rather than dumping the user on the feed. Quoted
            // naddr references inside a note DO resolve; see QuoteRef.
            else -> null
        }
    }

    private fun noteRoute(id: String, decoder: NostrEntityDecoder): DeepLinkTarget? {
        val hex = when {
            id.startsWith("note1") -> decoder.noteToHex(id)
            id.startsWith("nevent1") -> decoder.neventToHex(id)
            isHex64(id) -> id
            else -> null
        } ?: return null
        return DeepLinkTarget(Screen.NoteDetail.createRoute(hex))
    }

    private fun profileRoute(id: String, decoder: NostrEntityDecoder): DeepLinkTarget? {
        val hex = when {
            id.startsWith("npub1") -> decoder.npubToHex(id)
            id.startsWith("nprofile1") -> decoder.nprofileToHex(id)
            isHex64(id) -> id
            else -> null
        } ?: return null
        return DeepLinkTarget(Screen.Profile.createRoute(hex))
    }

    /**
     * The extras [com.nostrvault.service.LocalNotificationService] puts on its
     * tap intent. `type` is the notification kind, `eventId` the event the
     * notification was raised for (not necessarily a note), `author` the
     * sender's hex pubkey, `npub` the account it arrived for.
     */
    fun fromNotification(
        type: String?,
        eventId: String?,
        author: String?,
        npub: String?,
        /** The post to open, looked up when the notification went out. */
        noteId: String? = null,
    ): DeepLinkTarget? {
        val account = npub?.takeIf { it.isNotBlank() }
        if (type == null) return null
        return when (type) {
            // A NIP-04 DM opens the conversation, not its event id.
            "dm" -> author?.takeIf { isHex64(it) }
                ?.let { DeepLinkTarget(Screen.DMThread.createRoute(it), account) }
            // A gift wrap's author is the one-time wrapping key, not the sender
            // (that is only known after decrypting), so it opens the inbox —
            // as iOS does. Opening a thread with the wrap key showed a stranger.
            "giftwrap" -> DeepLinkTarget(Screen.DMInbox.route, account)
            // A post-related notification opens the post, matching iOS: the
            // mention or reply itself, or your note a reaction, repost or zap
            // is about, looked up when the notification went out ([noteId]).
            // Without that, a mention or reply is a note and opens as one; a
            // reaction, repost or zap lands in the Relay tab, which resolves
            // the post from the stored event (NotificationTarget.targetNoteId).
            in NotificationTarget.RELAY_TYPES -> noteId?.takeIf { isHex64(it) }
                ?.let { DeepLinkTarget(Screen.NoteDetail.createRoute(it), account) }
                ?: eventId?.takeIf { isHex64(it) && type in NOTE_TYPES }
                    ?.let { DeepLinkTarget(Screen.NoteDetail.createRoute(it), account) }
                ?: eventId?.takeIf { isHex64(it) }
                ?.let {
                    DeepLinkTarget(
                        route = Screen.Dashboard.route,
                        accountNpub = account,
                        relayFocus = RelayFocusRequest(type = type, eventId = it),
                    )
                }
            // The catch-up marker deliberately has no event id.
            "summary" -> DeepLinkTarget(Screen.Feed.route, account)
            else -> null
        }
    }

    /** Notification types whose own event is the post. */
    private val NOTE_TYPES = setOf("mention", "reply", "quote")

    private fun isHex64(s: String): Boolean =
        s.length == 64 && s.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }
}
