package com.nostrvault.service

/**
 * Which of your posts a blob delete may offer to take down too, and the
 * NIP-09 request that does it. Port of iOS `NostrService.ownEvents(referencingBlob:)`
 * and `deleteOwnEvents(referencingBlob:)`.
 */
object BlobPostDeletion {
    /**
     * Notes, picture and video posts, file metadata and comments. Never a
     * profile (kind 0, whose picture may be this file), a list, a DM or an
     * article.
     */
    val POST_KINDS: Set<Int> = setOf(1, 20, 21, 22, 1063, 1111)

    /** [owner]'s posts in [events] that link the blob [sha256], in their text or tags (imeta). */
    fun referencing(events: List<NostrEvent>, owner: String, sha256: String): List<NostrEvent> {
        val hash = sha256.lowercase()
        if (owner.isEmpty() || hash.length != 64) return emptyList()
        return events.filter { event ->
            event.pubkey == owner && event.kind in POST_KINDS && (
                event.content.lowercase().contains(hash) ||
                    event.tags.any { tag -> tag.any { it.lowercase().contains(hash) } }
                )
        }
    }

    /** One kind-5 request naming them all: an `e` tag per post, then a `k` tag per kind. */
    fun deletionTags(targets: List<NostrEvent>): List<List<String>> =
        targets.map { listOf("e", it.id) } +
            targets.map { it.kind }.toSortedSet().map { listOf("k", it.toString()) }
}
