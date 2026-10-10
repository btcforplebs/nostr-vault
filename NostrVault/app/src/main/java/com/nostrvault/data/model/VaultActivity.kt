package com.nostrvault.data.model

import com.nostrvault.util.ZapAmount
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.time.Instant
import java.time.ZoneId

/**
 * One line on the Vault tab's "Vault" list: everything other people did that
 * reached you, newest first, the way a notifications page reads. Likes, zaps
 * and reposts of the same post fold into one line ("Ann and 3 others liked
 * your note"); replies, mentions and quotes each get their own. Pure logic,
 * kept free of Android types so unit tests can pin it. Port of iOS
 * Models/VaultActivity.swift (#506).
 */
data class VaultActivity(
    val id: String,
    val kind: Kind,
    /** Who did it, newest first, each once. */
    val actors: List<String>,
    /** The newest of them, unix seconds. */
    val createdAt: Long,
    /**
     * The note a tap opens: their reply or mention, or your post they liked.
     * Null for follows, which open the profile.
     */
    val openId: String?,
    /**
     * Their words (reply, mention, quote, article title, zap comment), or
     * your post's text when they only reacted to it.
     */
    val preview: String,
    /** Reactions only: the emoji, newest first, each once. */
    val emojis: List<String> = emptyList(),
    /** Zaps only: the total. */
    val sats: Long = 0,
) {
    enum class Kind { REPLY, MENTION, QUOTE, REACTION, REPOST, ZAP, ARTICLE, HIGHLIGHT, FOLLOW }

    /** The event fields the list needs. */
    data class Event(
        val id: String,
        val pubkey: String,
        val kind: Int,
        val createdAt: Long,
        val content: String,
        val tags: List<List<String>>,
    )

    /** A follow from the relay's follower ledger: who, and when (unix seconds). */
    data class Follow(val pubkey: String, val at: Long)

    /**
     * Likes, reposts and plain zaps quote your post; everything else quotes
     * them. Folded zaps ("zap-<post>") carry no words of their own.
     */
    val aboutYourPost: Boolean
        get() = when (kind) {
            Kind.REACTION, Kind.REPOST -> true
            Kind.ZAP -> id.startsWith("zap-")
            else -> false
        }

    companion object {
        const val REACTION_KIND = 7
        const val ZAP_KIND = 9735
        val REPOST_KINDS = setOf(6, 16)

        private val json = Json { ignoreUnknownKeys = true }

        /**
         * Builds the list. [noteKinds] are the kinds the Vault lists (the relay
         * tab's); [isBlocked] drops blocked authors and, for posts that tag
         * you, [isOutside] drops replies from outside your network (the Notes
         * list hides those too). [follows] come from the follower ledger;
         * those on one day (in [zone]) fold into one line.
         */
        fun build(
            events: List<Event>,
            owner: String,
            noteKinds: Set<Int>,
            follows: List<Follow> = emptyList(),
            isBlocked: (String) -> Boolean = { false },
            isOutside: (String) -> Boolean = { false },
            zone: ZoneId = ZoneId.systemDefault(),
        ): List<VaultActivity> {
            if (owner.isEmpty()) return emptyList()

            val myText = HashMap<String, String>()
            for (event in events) {
                if (event.pubkey == owner && event.kind in noteKinds && event.kind !in REPOST_KINDS) {
                    myText.getOrPut(event.id) { preview(event) }
                }
            }

            val singles = ArrayList<VaultActivity>()
            // Folded lines, by kind and target, in the order first seen.
            val folds = LinkedHashMap<String, Fold>()
            val seen = HashSet<String>()

            fun fold(kind: Kind, target: String, actor: String, at: Long, emoji: String? = null, sats: Long = 0) {
                val f = folds.getOrPut("${kind.name.lowercase()}-$target") { Fold(kind, target) }
                f.actors += actor
                f.at = maxOf(f.at, at)
                if (emoji != null) f.emojis += emoji
                f.sats += sats
            }

            // Newest first, so each fold's actor list comes out newest first.
            for (event in events.sortedByDescending { it.createdAt }) {
                if (event.pubkey == owner || !seen.add(event.id)) continue

                if (event.kind == REACTION_KIND) {
                    if (isBlocked(event.pubkey)) continue
                    val target = firstTag("e", event.tags) ?: continue
                    if (target !in myText) continue
                    fold(Kind.REACTION, target, event.pubkey, event.createdAt, emoji = event.content.ifEmpty { "+" })
                    continue
                }

                if (event.kind == ZAP_KIND) {
                    if (firstTag("p", event.tags) != owner) continue
                    val request = zapRequest(event.tags)
                    val sender = request?.pubkey ?: continue
                    if (sender == owner || isBlocked(sender)) continue
                    val sats = ZapAmount.sats(event.tags)
                    // The note comes from the signed request, as the Zaps list reads it.
                    val target = firstTag("e", request.tags) ?: firstTag("e", event.tags)
                    val comment = request.content.trim()
                    if (target != null && target in myText && comment.isEmpty()) {
                        fold(Kind.ZAP, target, sender, event.createdAt, sats = sats)
                    } else {
                        // A zap with words, or on your profile: its own line.
                        val mine = target?.takeIf { it in myText }
                        singles += VaultActivity(
                            id = event.id, kind = Kind.ZAP, actors = listOf(sender), createdAt = event.createdAt,
                            openId = mine,
                            preview = comment.ifEmpty { mine?.let { myText[it] } ?: "" },
                            sats = sats,
                        )
                    }
                    continue
                }

                if ((event.kind !in noteKinds && event.kind !in REPOST_KINDS) || isBlocked(event.pubkey)) continue

                if (event.kind in REPOST_KINDS) {
                    val target = firstTag("e", event.tags) ?: continue
                    if (target !in myText) continue
                    fold(Kind.REPOST, target, event.pubkey, event.createdAt)
                    continue
                }

                val tagsYou = event.tags.any { it.size >= 2 && it[0] == "p" && it[1] == owner }
                if (!tagsYou || isOutside(event.pubkey)) continue

                val kind = when (event.kind) {
                    VaultNoteScope.ARTICLE_KIND -> Kind.ARTICLE
                    VaultNoteScope.HIGHLIGHT_KIND -> Kind.HIGHLIGHT
                    else -> {
                        val quoted = firstTag("q", event.tags)
                        when {
                            quoted != null && quoted in myText -> Kind.QUOTE
                            event.tags.any { it.size >= 2 && (it[0] == "e" || it[0] == "E") } -> Kind.REPLY
                            else -> Kind.MENTION
                        }
                    }
                }
                singles += VaultActivity(
                    id = event.id, kind = kind, actors = listOf(event.pubkey), createdAt = event.createdAt,
                    openId = event.id, preview = preview(event),
                )
            }

            val folded = folds.map { (key, f) ->
                VaultActivity(
                    id = key, kind = f.kind, actors = f.actors.distinct(), createdAt = f.at,
                    openId = f.target, preview = myText[f.target] ?: "",
                    emojis = f.emojis.distinct(), sats = f.sats,
                )
            }

            // Follows on one day fold into one line, like a notifications page.
            val followLines = follows
                .filter { it.pubkey != owner && !isBlocked(it.pubkey) }
                .groupBy { Instant.ofEpochSecond(it.at).atZone(zone).toLocalDate() }
                .map { (day, list) ->
                    val sorted = list.sortedByDescending { it.at }
                    VaultActivity(
                        id = "follow-$day", kind = Kind.FOLLOW, actors = sorted.map { it.pubkey }.distinct(),
                        createdAt = sorted.first().at, openId = null, preview = "",
                    )
                }

            return (singles + folded + followLines).sortedWith(
                compareByDescending<VaultActivity> { it.createdAt }.thenBy { it.id },
            )
        }

        /**
         * One line of text for an event: an article's title or summary, else
         * its content with whitespace runs collapsed.
         */
        fun preview(event: Event): String {
            if (event.kind == VaultNoteScope.ARTICLE_KIND) {
                firstTag("title", event.tags)?.let { return it }
                firstTag("summary", event.tags)?.let { return it }
            }
            return event.content.split(WHITESPACE).filter { it.isNotEmpty() }.joinToString(" ")
        }

        /** "Ann", "Ann and Bob", "Ann and 3 others", from the actors' names. */
        fun who(actors: List<String>, name: (String) -> String): String = when (actors.size) {
            0 -> "Someone"
            1 -> name(actors[0])
            2 -> "${name(actors[0])} and ${name(actors[1])}"
            else -> "${name(actors[0])} and ${actors.size - 1} others"
        }

        private val WHITESPACE = Regex("\\s+")

        private class Fold(val kind: Kind, val target: String) {
            val actors = ArrayList<String>()
            var at = 0L
            val emojis = ArrayList<String>()
            var sats = 0L
        }

        private class ZapRequest(val pubkey: String, val content: String, val tags: List<List<String>>)

        /** The zap request (kind 9734) a receipt carries in its `description` tag. */
        private fun zapRequest(receiptTags: List<List<String>>): ZapRequest? {
            val description = firstTag("description", receiptTags) ?: return null
            val obj = runCatching { json.parseToJsonElement(description) as? JsonObject }.getOrNull() ?: return null
            val pubkey = (obj["pubkey"] as? JsonPrimitive)?.content?.takeIf { it.isNotEmpty() } ?: return null
            val content = (obj["content"] as? JsonPrimitive)?.content ?: ""
            val tags = (obj["tags"] as? JsonArray)?.mapNotNull { tag ->
                (tag as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.content }
            }.orEmpty()
            return ZapRequest(pubkey, content, tags)
        }

        private fun firstTag(name: String, tags: List<List<String>>): String? =
            tags.firstOrNull { it.size >= 2 && it[0] == name && it[1].isNotEmpty() }?.get(1)
    }
}
