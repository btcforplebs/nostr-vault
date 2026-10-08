package com.nostrvault.ui.navigation

import com.nostrvault.data.model.VaultViewMode
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull

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

    /** The folded "N new followers" alert: lands on the Followers list, no event. */
    const val FOLLOWERS = "followers"

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
        FOLLOWERS -> VaultViewMode.FOLLOWERS
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

/** The fields of a Nostr event a note screen needs, carried in a notification. */
data class CarriedEvent(
    val id: String,
    val pubkey: String,
    val createdAt: Long,
    val kind: Int,
    val tags: List<List<String>>,
    val content: String,
)

/**
 * The post a relay notification opens, carried inside the notification.
 *
 * The relay raises its NOTIFY marker only after storing the event, so the app
 * reads that event — and for a like, zap or repost the post it is about — from
 * the on-device relay and puts both on the tap intent. The tap then opens the
 * post from that copy: no relay round trip and no hunt through the Relay tab,
 * even on a cold start. Same as iOS `NotificationNote`.
 */
object NotificationNote {
    /** Intent extra holding the notifying event, as NIP-01 JSON. */
    const val EVENT_EXTRA = "notif_event"
    /** Intent extra holding the post a like, zap or repost is about. */
    const val TARGET_EXTRA = "notif_target"

    /**
     * Past this size an event stays out of the intent and the tap loads it by
     * id. A PendingIntent lives in the system process; a long-form post has
     * no business there.
     */
    const val MAX_ENCODED_CHARS = 32 * 1024

    private val json = Json { ignoreUnknownKeys = true }

    /** The event's JSON for an intent extra, or null if malformed or too big. */
    fun encode(event: JsonObject): String? {
        val text = event.toString()
        if (text.length > MAX_ENCODED_CHARS) return null
        return text.takeIf { decode(it) != null }
    }

    /** The event from an intent extra; null for anything that is not a whole event. */
    fun decode(text: String?): CarriedEvent? {
        if (text.isNullOrEmpty()) return null
        val obj = try { json.parseToJsonElement(text) as? JsonObject } catch (_: Exception) { null } ?: return null
        fun str(key: String) = (obj[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
        val id = str("id")?.takeIf(NotificationTarget::isHex64) ?: return null
        val pubkey = str("pubkey")?.takeIf(NotificationTarget::isHex64) ?: return null
        val createdAt = (obj["created_at"] as? JsonPrimitive)?.longOrNull ?: return null
        val kind = (obj["kind"] as? JsonPrimitive)?.intOrNull ?: return null
        val content = str("content") ?: return null
        val tags = try {
            (obj["tags"] as? JsonArray)?.map { tag ->
                (tag as JsonArray).map { (it as JsonPrimitive).content }
            }
        } catch (_: Exception) { null } ?: return null
        return CarriedEvent(id, pubkey, createdAt, kind, tags, content)
    }
}
