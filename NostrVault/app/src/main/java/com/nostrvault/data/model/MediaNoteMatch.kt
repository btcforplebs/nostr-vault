package com.nostrvault.data.model

import com.nostrvault.service.NostrEvent

/**
 * The notes that use one media file, for the Vault media viewer's swipe up
 * (Logen 2026-11-04): every note on the user's own vault that names the file
 * by its URL or its sha256 (a Blossom name), in the text or in any tag
 * (imeta included), whoever wrote it. Nothing is asked of the network.
 * iOS twin: `MediaNoteMatch.swift`.
 */
object MediaNoteMatch {
    /** Notes, pictures, videos, file metadata, comments, articles, highlights, polls. */
    val KINDS: Set<Int> = setOf(1, 20, 21, 22, 1063, 1111, 30023, 9802, 1068, 34235, 34236)

    /** The sha256 a Blossom URL is named by (".../<64 hex>[.ext]"), lowercased. */
    fun sha256Of(url: String): String? {
        val name = url.substringBefore('?').substringBefore('#').substringAfterLast('/').substringBefore('.').lowercase()
        return name.takeIf { it.length == 64 && it.all { c -> c in '0'..'9' || c in 'a'..'f' } }
    }

    /** Whether [event] names the file by [url] or [sha256], in its text or a tag. */
    fun uses(event: NostrEvent, url: String, sha256: String?): Boolean {
        val needles = listOfNotNull(url.lowercase().takeIf { it.isNotEmpty() }, sha256?.lowercase()?.takeIf { it.length == 64 })
        if (needles.isEmpty()) return false
        fun hit(text: String): Boolean { val t = text.lowercase(); return needles.any { t.contains(it) } }
        return hit(event.content) || event.tags.any { tag -> tag.any(::hit) }
    }

    /** Every note in [events] that uses the file, newest first, each once. */
    fun notesUsing(events: List<NostrEvent>, url: String, sha256: String? = sha256Of(url)): List<NostrEvent> =
        events.asSequence()
            .filter { it.kind in KINDS && uses(it, url, sha256) }
            .distinctBy { it.id }
            .sortedWith(compareByDescending<NostrEvent> { it.createdAt }.thenBy { it.id })
            .toList()
}
