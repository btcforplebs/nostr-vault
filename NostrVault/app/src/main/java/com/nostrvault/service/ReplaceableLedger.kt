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
        // Both count: the ledger may hold an older event accepted before the
        // cached copy (fallbackSeen, e.g. a kind 0 from disk) finished loading.
        val recorded = newest[key]
        if (recorded == null && fallbackSeen == null) return true
        val seen = maxOf(recorded ?: Long.MIN_VALUE, fallbackSeen ?: Long.MIN_VALUE)
        if (createdAt != seen) return createdAt > seen
        // Same second: lowest id wins. With no id on record (the copy came
        // from disk) keep accepting, as that is most likely the same event.
        val seenId = if (recorded == seen) newestId[key] else null
        return seenId == null || id <= seenId
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

/**
 * Merges a map loaded from disk with what relays delivered while it loaded,
 * keeping the newer of each by created_at (an unknown created_at loses).
 */
internal fun <V> mergeNewer(disk: Map<String, V>, memory: Map<String, V>, createdAt: (V) -> Long?): Map<String, V> {
    val merged = disk.toMutableMap()
    for ((key, value) in memory) {
        val onDisk = merged[key]
        if (onDisk == null || (createdAt(value) ?: Long.MIN_VALUE) >= (createdAt(onDisk) ?: Long.MIN_VALUE)) {
            merged[key] = value
        }
    }
    return merged
}
