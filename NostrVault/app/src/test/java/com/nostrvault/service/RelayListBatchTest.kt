package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RelayListBatchTest {
    @Test
    fun manyListsScheduleOnePublish() {
        val batch = RelayListBatch()
        val schedules = (0 until 2_000).count { i ->
            batch.offer("pk$i", listOf("wss://r$i"), listOf("wss://w$i"), 100L).schedule
        }
        assertEquals(1, schedules)
        val (read, write) = batch.drain()
        assertEquals(2_000, read.size)
        assertEquals(2_000, write.size)
        assertTrue(batch.offer("pk1", listOf("wss://x"), emptyList(), 200L).schedule)
    }

    @Test
    fun olderListNeverReplacesNewer() {
        val batch = RelayListBatch()
        batch.offer("a", listOf("wss://new"), listOf("wss://new"), 200L)
        assertFalse(batch.offer("a", listOf("wss://old"), listOf("wss://old"), 100L).accepted)
        val (read, write) = batch.drain()
        assertEquals(listOf("wss://new"), read["a"])
        assertEquals(listOf("wss://new"), write["a"])
        assertEquals(200L, batch["a"])
        assertNull(batch["b"])
        assertFalse(batch.offer("a", listOf("wss://old"), emptyList(), 150L).accepted)
    }

    @Test
    fun emptyHalfLeavesThePublishedOne() {
        val batch = RelayListBatch()
        batch.offer("a", emptyList(), listOf("wss://w"), 100L)
        val (read, write) = batch.drain()
        assertTrue(read.isEmpty())
        assertEquals(listOf("wss://w"), write["a"])
    }
}
