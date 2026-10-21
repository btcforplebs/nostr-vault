package com.nostrvault.service

import com.nostrvault.data.model.FeedNote
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull

/**
 * Keeping deleted posts gone. A relay that ignores NIP-09 still serves a
 * deleted post on a refresh, a reply thread fetches it back as the root,
 * and a repost or quote carries its text. These rules read your own
 * kind-5 requests (from this device or another) and hide their targets.
 * Twin: iOS `DeletedNotes`.
 */
object DeletedNotes {
    const val REQUEST_KIND = 5

    /** The posts a kind-5 request names: its `e` tags, hex ids only. */
    fun targets(requestTags: List<List<String>>): Set<String> =
        requestTags.asSequence()
            .filter { it.size >= 2 && it[0] == "e" }
            .map { it[1].lowercase() }
            .filter { id -> id.length == 64 && id.all { it in '0'..'9' || it in 'a'..'f' } }
            .toSet()

    /**
     * Only your own requests count. Anyone can publish a kind 5 naming
     * your post; relays ignore those, and so do we.
     */
    fun isOwnRequest(kind: Int, pubkey: String, owner: String): Boolean =
        kind == REQUEST_KIND && owner.isNotEmpty() && pubkey == owner

    /**
     * Your own request, and really yours: a relay can send a kind 5 under
     * your pubkey naming any post, and a forged one would hide that post on
     * this device for good. Only the id hash and signature prove you sent
     * it. [verify] is `HavenBridge::verifyEvent` in the app.
     */
    fun isOwnSignedRequest(event: JsonObject, owner: String, verify: (String) -> Boolean): Boolean {
        val kind = (event["kind"] as? JsonPrimitive)?.intOrNull ?: return false
        val pubkey = (event["pubkey"] as? JsonPrimitive)?.contentOrNull ?: return false
        return isOwnRequest(kind, pubkey, owner) && verify(event.toString())
    }

    /** Whether a row stays off screen: the deleted post, or a repost of it. */
    fun hides(note: FeedNote, deleted: Set<String>): Boolean {
        if (deleted.isEmpty()) return false
        if (note.id in deleted) return true
        val original = note.repostedEventId
        return original != null && original in deleted
    }

    fun visible(notes: List<FeedNote>, deleted: Set<String>): List<FeedNote> =
        if (deleted.isEmpty()) notes else notes.filterNot { hides(it, deleted) }

    /** A cache keyed by id, without the deleted posts under any key. */
    fun visible(cache: Map<String, FeedNote>, deleted: Set<String>): Map<String, FeedNote> =
        if (deleted.isEmpty()) cache else cache.filter { (key, note) -> key !in deleted && !hides(note, deleted) }
}
