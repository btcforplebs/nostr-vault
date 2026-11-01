package com.nostrvault.util

/**
 * A small thread-safe LRU for pure parse results (text in, value out).
 *
 * Compose `remember` forgets when a feed row leaves the screen, so a note that
 * scrolls back in was parsed again on the main thread. Results here outlive the
 * row, so each note's text is parsed once while it stays in recent use.
 * Plain Kotlin (not android.util.LruCache) so JVM unit tests can use it.
 */
class ParseCache<K : Any, V : Any>(private val maxEntries: Int) {
    private val map = object : LinkedHashMap<K, V>(maxEntries, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<K, V>?): Boolean = size > maxEntries
    }

    fun getOrPut(key: K, compute: () -> V): V {
        synchronized(map) { map[key]?.let { return it } }
        // Computed outside the lock: two threads may both parse once; the
        // result is the same, and nobody waits on a slow parse.
        val value = compute()
        synchronized(map) { map[key] = value }
        return value
    }

    val size: Int get() = synchronized(map) { map.size }
}
