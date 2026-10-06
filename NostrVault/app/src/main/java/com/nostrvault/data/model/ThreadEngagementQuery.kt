package com.nostrvault.data.model

/**
 * The relay requests behind the note screen's Thread Stats toggle (iOS #325).
 *
 * A relay applies `limit` per filter, so one filter over every note in a
 * thread shares one budget between all of them: one busy note fills it and
 * the rest come back short or empty. Splitting the thread into small batches
 * gives each batch its own budget. Batches go one after another on each
 * relay's socket.
 */
object ThreadEngagementQuery {
    /** Notes per request. Small enough that one popular note can't starve the others in its batch of much. */
    const val BATCH_SIZE = 10

    /** Events per request, per relay. */
    const val LIMIT = 500

    /** Reposts, reactions, zap receipts. */
    val KINDS = listOf(6, 7, 9735)

    data class Request(val subscriptionId: String, val noteIds: List<String>) {
        val filter: String
            get() = """{"kinds":[${KINDS.joinToString(",")}],"#e":[${noteIds.joinToString(",") { "\"$it\"" }}],"limit":$LIMIT}"""
    }

    /** One request per batch of [noteIds], in a stable order so the same thread always splits the same way. */
    fun requests(noteIds: Collection<String>, subscriptionPrefix: String): List<Request> =
        noteIds.toSortedSet().toList()
            .chunked(BATCH_SIZE)
            .mapIndexed { index, batch -> Request("$subscriptionPrefix-$index", batch) }

    /** The whole fetch's time limit: 6 s, plus 2 s per extra batch, at most 20 s. */
    fun timeoutMs(requestCount: Int): Long =
        minOf(6_000L + 2_000L * (requestCount - 1).coerceAtLeast(0), 20_000L)

    /** The thread note an engagement event targets: its last `e` tag naming one (NIP-25). */
    fun targetNoteId(tags: List<List<String>>, threadIds: Set<String>): String? =
        tags.lastOrNull { it.size >= 2 && it[0] == "e" && it[1] in threadIds }?.get(1)
}
