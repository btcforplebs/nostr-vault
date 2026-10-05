package com.nostrvault.service.music

import org.junit.Assert.assertEquals
import org.junit.Test
import kotlin.random.Random

class MusicQueueOrderTest {
    private val queue = listOf("a", "b", "c", "d", "e")

    @Test fun shuffleKeepsThePlayingSongFirstAndEverySongOnce() {
        repeat(20) { seed ->
            val shuffled = MusicQueueOrder.shuffleAround(queue, 2, Random(seed))
            assertEquals("c", shuffled.first())
            assertEquals(queue.sorted(), shuffled.sorted())
        }
    }

    @Test fun shuffleWithABadIndexLeavesTheQueue() {
        assertEquals(queue, MusicQueueOrder.shuffleAround(queue, 9))
    }

    @Test fun unshufflePutsTheOriginalOrderBackAroundThePlayingSong() {
        val shuffled = listOf("c", "e", "a", "d", "b")
        assertEquals(queue to 4, MusicQueueOrder.unshuffle(queue, shuffled, "e") { it })
        // Nothing remembered (shuffle was on before this queue): keep the order.
        assertEquals(shuffled to 1, MusicQueueOrder.unshuffle(emptyList(), shuffled, "e") { it })
    }

    @Test fun repeatCyclesOffAllOne() {
        assertEquals(MusicRepeatMode.ALL, MusicRepeatMode.OFF.next())
        assertEquals(MusicRepeatMode.ONE, MusicRepeatMode.ALL.next())
        assertEquals(MusicRepeatMode.OFF, MusicRepeatMode.ONE.next())
    }
}
