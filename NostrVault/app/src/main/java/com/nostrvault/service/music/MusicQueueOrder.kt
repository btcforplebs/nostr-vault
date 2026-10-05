package com.nostrvault.service.music

import kotlin.random.Random

/** Off, the whole queue over again, or this song over again. iOS: MusicPlayerService.RepeatMode. */
enum class MusicRepeatMode {
    OFF, ALL, ONE;

    /** Off → repeat all → repeat one → off. */
    fun next(): MusicRepeatMode = entries[(ordinal + 1) % entries.size]
}

/**
 * How shuffle reorders the queue. The queue itself is put in shuffled order
 * (not the player's hidden shuffle order), so Up Next can list it as it will
 * play and turning shuffle off puts back the order it was played in.
 * iOS: MusicPlayerService.toggleShuffle / playShuffled.
 */
object MusicQueueOrder {
    /** The song at [index] first, keeping on; everything else after it, shuffled. */
    fun <T> shuffleAround(queue: List<T>, index: Int, random: Random = Random.Default): List<T> {
        if (index !in queue.indices) return queue
        val rest = queue.toMutableList().apply { removeAt(index) }.shuffled(random)
        return listOf(queue[index]) + rest
    }

    /**
     * Back to [original] order, with the playing song ([currentId]) in its
     * place there. Returns the queue and the playing song's index in it.
     */
    fun <T> unshuffle(original: List<T>, shuffled: List<T>, currentId: String, id: (T) -> String): Pair<List<T>, Int> {
        val restored = original.ifEmpty { shuffled }
        val at = restored.indexOfFirst { id(it) == currentId }.coerceAtLeast(0)
        return restored to at
    }
}
