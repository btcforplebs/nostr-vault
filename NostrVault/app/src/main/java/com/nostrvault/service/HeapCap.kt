package com.nostrvault.service

/**
 * A lower size cap for files this app holds whole in memory, on a phone whose
 * app heap is small.
 *
 * A locked DM file and a private copy are read into one array and encrypted
 * or decrypted into a second, so a file takes two to three times its size in
 * the Java heap. The caps (100 MB, 50 MB for a photo) assume the 512 MB heap
 * an ordinary phone gives this app. A 2 GB phone gives 128 to 256 MB, where a
 * file well under the cap runs the heap out and ends the app (nothing catches
 * an OutOfMemoryError). So at or under [SMALL_HEAP] the cap is a sixth of the
 * heap. Above it nothing changes.
 */
object HeapCap {
    const val SMALL_HEAP = 400L shl 20

    /** [limit], or less on a small heap. [heapMax] is the most this app's Java heap may grow to. */
    fun of(limit: Long, heapMax: Long = Runtime.getRuntime().maxMemory()): Long =
        if (heapMax in 1..SMALL_HEAP) minOf(limit, heapMax / 6) else limit

    /** What to say when a file is over a cap this phone lowered; null when the cap is the usual one. */
    fun tooBigHere(limit: Long, heapMax: Long = Runtime.getRuntime().maxMemory()): String? {
        val cap = of(limit, heapMax)
        return if (cap < limit) "Too big for this phone's memory (at most ${cap shr 20} MB here)." else null
    }
}
