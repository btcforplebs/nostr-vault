package com.nostrvault.ui.screens

/**
 * Keeps Media's full loads from undoing each other (Vault tab review
 * 2026-11-27, finding 2). Only the newest load may publish, and its result
 * leaves out any file removed after it began: a slow load (mirror `/list`
 * calls wait up to 10 s) that started before a delete brought the deleted
 * tile back. A load that starts after the removal may still show the file, so
 * a server that kept it is seen. Thread-safe.
 */
internal class MediaLoadGate {
    private var generation = 0L
    private val removedIn = HashMap<String, Long>()

    /** Starts a load; anything still running from before becomes stale. */
    @Synchronized
    fun begin(): Long {
        generation += 1
        removedIn.clear()
        return generation
    }

    @Synchronized
    fun isCurrent(load: Long): Boolean = load == generation

    /** A file left the list while [load]'s or a newer load ran. */
    @Synchronized
    fun removed(sha256: String) {
        if (generation > 0) removedIn[sha256.lowercase()] = generation
    }

    /**
     * A file came back (folder Landed or a file-note Added) after a removal while
     * the same load ran: the load may show it again.
     */
    @Synchronized
    fun landed(sha256: String) {
        removedIn.remove(sha256.lowercase())
    }

    /** [items] as [load] may publish them, or null when a newer load started. */
    @Synchronized
    fun result(load: Long, items: List<BlossomMediaItem>): List<BlossomMediaItem>? {
        if (load != generation) return null
        if (removedIn.isEmpty()) return items
        return items.filter { (removedIn[it.sha256.lowercase()] ?: 0L) < load }
    }
}
