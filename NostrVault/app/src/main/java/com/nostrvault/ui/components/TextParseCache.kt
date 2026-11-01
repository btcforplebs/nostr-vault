package com.nostrvault.ui.components

/**
 * Note text parsed once, kept across rows leaving and re-entering the screen.
 *
 * `remember` dies with a LazyColumn item, so every row that scrolled back in
 * ran the regex passes and bech32 decoding again, on main, 3–5 times per note
 * (sweep 11-01). Both parses depend only on their inputs, so a bounded,
 * least-recently-used map of results is all it takes.
 */
internal class TextParseCache<K : Any, V : Any>(private val max: Int) {
    private val map = object : LinkedHashMap<K, V>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<K, V>?) = size > max
    }

    fun getOrPut(key: K, compute: () -> V): V {
        synchronized(map) { map[key] }?.let { return it }
        val value = compute()
        synchronized(map) { map[key] = value }
        return value
    }

    val size: Int get() = synchronized(map) { map.size }

    fun clear() = synchronized(map) { map.clear() }

    companion object {
        /** About two feeds' worth of visible and nearby rows. */
        const val NOTES = 1_000
    }
}
