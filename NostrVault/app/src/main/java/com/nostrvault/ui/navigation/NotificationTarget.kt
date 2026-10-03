package com.nostrvault.ui.navigation

import com.nostrvault.data.model.VaultViewMode
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * A notification tap that should land on one event in the Relay tab.
 *
 * @param type the notification type from the relay's NOTIFY marker
 *   (`mention`, `reply`, `reaction`, `repost`, `zap`).
 * @param eventId the id of the event the notification was raised for. For a
 *   reaction, repost or zap that is the kind 7 / 6 / 9735 event itself, not the
 *   post it is about — see [NotificationTarget.targetNoteId].
 */
data class RelayFocusRequest(
    val type: String,
    val eventId: String,
)

/**
 * Pure mapping from a notification's event to the post a tap should land on.
 * Port of iOS `consumeRelayFocus`/`focusCandidates` (PR #95), kept free of
 * Android types so unit tests can pin it.
 */
object NotificationTarget {

    /** Notification types that are about a post and land in the Relay tab. */
    val RELAY_TYPES = setOf("mention", "reply", "quote", "reaction", "repost", "zap")

    /**
     * The post a tap should open.
     *
     * - mention / reply / quote: the notifying note is the post.
     * - reaction (NIP-25) and repost (NIP-18): the last `e` tag. Earlier `e`
     *   tags can name the thread root of the reacted-to reply.
     * - zap (NIP-57): the receipt's `e` tag, the zapped note. A profile zap has
     *   none, so there is no post to land on and this returns null.
     */
    fun targetNoteId(type: String, eventId: String, tags: List<List<String>>): String? =
        when (type) {
            "reaction", "repost", "zap" -> lastETag(tags)
            else -> eventId.takeIf(::isHex64)
        }

    /**
     * Ids to look for in the Relay tab's list, best first: the notification's
     * own event (a repost card or a reply is listed as itself), then what it
     * points at (a reaction or zap is listed under the note it targets), last
     * `e` tag first per NIP-25.
     */
    fun focusCandidates(eventId: String, tags: List<List<String>>): List<String> =
        (listOf(eventId) + eTags(tags).reversed()).distinct()

    /**
     * Which Relay-tab list holds the event: likes → Likes Received, zaps → Zaps
     * Received, everything else → Notes / All. Zaps-only mode hides the Likes
     * list, so a reaction there falls back to Notes.
     */
    fun viewFor(type: String, zapsOnly: Boolean): VaultViewMode = when (type) {
        "reaction" -> if (zapsOnly) VaultViewMode.NOTES else VaultViewMode.LIKES
        "zap" -> VaultViewMode.ZAPS
        else -> VaultViewMode.NOTES
    }

    private fun eTags(tags: List<List<String>>): List<String> =
        tags.filter { it.size >= 2 && it[0] == "e" && isHex64(it[1]) }.map { it[1] }

    private fun lastETag(tags: List<List<String>>): String? = eTags(tags).lastOrNull()

    fun isHex64(s: String): Boolean =
        s.length == 64 && s.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }
}

/**
 * Parks a notification's target until the Relay tab can act on it. The tab's
 * screen and view model are created on navigation, so on a cold start (or the
 * first visit) the tap arrives before anything is listening; parking lets the
 * tab pick it up as it composes. Same role as iOS's `RelayFocus.pending`.
 */
object RelayFocus {
    private val _pending = MutableStateFlow<RelayFocusRequest?>(null)
    val pending: StateFlow<RelayFocusRequest?> = _pending

    fun request(request: RelayFocusRequest) { _pending.value = request }

    fun consume(): RelayFocusRequest? = _pending.value?.also { _pending.value = null }
}
