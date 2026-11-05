package com.nostrvault.widget

import com.nostrvault.data.model.FeedNote
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull

/**
 * What the Following and Mentions widgets list, and the events-stored count,
 * apart from [WidgetPublisher] so the rules can be tested.
 *
 * The Feed widget is headed "Following", so it lists only notes by people the
 * active account follows (and its own), whichever feed is open in the app.
 * Mentions are read from your own relay's inbox as well as the open feed, so a
 * mention by someone you don't follow still reaches the widget.
 */
object WidgetFeedRules {
    const val LIMIT = 10

    /** How many inbox events one mentions read asks for. */
    const val INBOX_LIMIT = 40

    /** Top-level notes by an author in [authors], or reposted by one: what Following shows. */
    fun followingNotes(notes: List<FeedNote>, authors: Set<String>): List<FeedNote> =
        notes.asSequence()
            // A reply out of its thread reads as an answer to a question the
            // widget cannot show (as on iOS).
            .filter { !it.isReply && (it.pubkey in authors || it.repostedBy in authors) }
            .take(LIMIT)
            .toList()

    /**
     * The Following widget's list.
     *
     * [authors] null: the follow list has not loaded, so nothing new is
     * added; what was already shown for this account ([previous]) stays.
     * With Following open, [fresh] is the whole list. With another feed
     * open, only the follows' notes that feed happens to hold are fresh, so
     * the notes already shown are kept beside them, newest first.
     */
    fun feed(
        fresh: List<VaultSnapshot.SnapshotNote>,
        authors: Set<String>?,
        openFeedIsFollowing: Boolean,
        previous: List<VaultSnapshot.SnapshotNote>,
    ): List<VaultSnapshot.SnapshotNote> {
        if (authors == null) return previous
        if (openFeedIsFollowing) return fresh.take(LIMIT)
        return (fresh + previous.filter { it.author in authors })
            .distinctBy { it.id }
            .sortedByDescending { it.createdAt }
            .take(LIMIT)
    }

    /** Both sources of mentions, each note once, newest first. */
    fun mentions(
        fromFeed: List<VaultSnapshot.SnapshotNote>,
        fromInbox: List<VaultSnapshot.SnapshotNote>,
    ): List<VaultSnapshot.SnapshotNote> =
        (fromFeed + fromInbox).distinctBy { it.id }.sortedByDescending { it.createdAt }.take(LIMIT)

    /**
     * Kind 1 notes from your inbox that mention [me] ([isMentionOf]), not by
     * a blocked author. The name is the author's key until [WidgetPublisher]
     * swaps in a profile.
     */
    fun inboxMentions(events: List<JsonObject>, me: String, blocked: Set<String>): List<VaultSnapshot.SnapshotNote> =
        events.mapNotNull { event ->
            fun str(k: String) = (event[k] as? JsonPrimitive)?.contentOrNull
            if ((event["kind"] as? JsonPrimitive)?.intOrNull != 1) return@mapNotNull null
            val id = str("id") ?: return@mapNotNull null
            val author = str("pubkey") ?: return@mapNotNull null
            val createdAt = (event["created_at"] as? JsonPrimitive)?.longOrNull ?: return@mapNotNull null
            val tags = (event["tags"] as? JsonArray).orEmpty().mapNotNull { tag ->
                (tag as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
            }
            if (author in blocked || !isMentionOf(me, author, tags)) return@mapNotNull null
            VaultSnapshot.SnapshotNote(
                id = id,
                author = author,
                displayName = author.take(8),
                text = lineText(str("content").orEmpty()),
                createdAt = createdAt * 1000,
            )
        }.distinctBy { it.id }.sortedByDescending { it.createdAt }.take(LIMIT)

    /** A widget row has no paragraphs, and the file should not hold a long-form note whole. */
    fun lineText(content: String): String = content.replace('\n', ' ').trim().take(200)

    /**
     * The count to publish: [fresh] once the app has counted this run, else
     * the last one on file. The service starts at "not counted" after a
     * reboot or an update, and a 0 then would be a number nobody counted.
     */
    fun eventsStored(fresh: Int?, previous: Int): Int = fresh ?: previous
}
