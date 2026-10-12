package com.nostrvault.service

/**
 * Deleting one of your posts: the NIP-09 request that asks relays to drop it,
 * and the local list without it. The app's own copy in `NostrService.events`
 * used to survive a delete until the next reload, so the Posts and Media
 * lists kept showing a post that was gone. Twin: iOS `NoteDeletion`.
 */
object NoteDeletion {
    /** A kind-5 request for one post. */
    fun requestTags(noteId: String): List<List<String>> = listOf(listOf("e", noteId))

    /** [events] without the deleted post. Nothing else moves. */
    fun without(events: List<NostrEvent>, noteId: String): List<NostrEvent> =
        events.filterNot { it.id == noteId }
}
