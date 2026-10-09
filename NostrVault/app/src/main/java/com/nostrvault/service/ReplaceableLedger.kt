package com.nostrvault.service

/**
 * Newest accepted replaceable event per "kind:pubkey". NIP-01: the newest
 * created_at wins, and a same-second tie goes to the lowest id.
 *
 * The created_at values cached on disk are seeded lazily on first use, once
 * [loadFromDisk] can read them (it returns null while storage is not ready).
 * NostrService is built by Hilt before Application.onCreate sets up storage,
 * so a seed at construction always read nothing.
 */
internal class ReplaceableLedger(private val loadFromDisk: () -> Map<String, Long>?) {
    private val newest = HashMap<String, Long>()
    private val newestId = HashMap<String, String>()
    private var seeded = false

    private fun seedLocked() {
        if (seeded) return
        val stamps = loadFromDisk() ?: return
        seeded = true
        for ((key, createdAt) in stamps) newest.merge(key, createdAt, ::maxOf)
    }

    private fun winsLocked(key: String, createdAt: Long, id: String, fallbackSeen: Long?): Boolean {
        val seen = newest[key] ?: fallbackSeen ?: return true
        if (createdAt != seen) return createdAt > seen
        // Same second: lowest id wins. With no id on record (seeded from disk)
        // keep accepting, as that is most likely the copy already cached.
        val seenId = newestId[key] ?: return true
        return id <= seenId
    }

    /** Cheap pre-check before the signature is verified. */
    @Synchronized
    fun mayReplace(key: String, createdAt: Long, id: String, fallbackSeen: Long? = null): Boolean {
        seedLocked()
        return winsLocked(key, createdAt, id, fallbackSeen)
    }

    /** Records a verified event; false if a newer one won meanwhile. */
    @Synchronized
    fun record(key: String, createdAt: Long, id: String, fallbackSeen: Long? = null): Boolean {
        seedLocked()
        if (!winsLocked(key, createdAt, id, fallbackSeen)) return false
        newest[key] = createdAt
        newestId[key] = id
        return true
    }

    /** What to persist, or null before the disk seed ran (saving then would drop it). */
    @Synchronized
    fun snapshot(keep: (String) -> Boolean): Map<String, Long>? {
        seedLocked()
        if (!seeded) return null
        return newest.filterKeys(keep)
    }
}
