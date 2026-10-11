package com.nostrvault.relay

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Every polled line reaches the console and its state is applied (iOS applyBatchedUpdate). */
class LogStoreTest {
    @After fun reset() = RelayForegroundService.clearErrorStates()

    @Test
    fun `every line in a batch is kept in order`() {
        val store = LogStore()
        store.applyLines(listOf("INFO one", "INFO two", "WARN three"))
        assertEquals(listOf("one", "two", "three"), store.logs.value.map { it.message })
    }

    @Test
    fun `boot status follows the last boot line`() {
        val store = LogStore()
        store.applyLines(listOf("Haven is booting up"))
        assertEquals("Booting Haven...", store.bootStatusMessage.value)
        store.applyLines(listOf("listening at 127.0.0.1:3355"))
        assertEquals("", store.bootStatusMessage.value)
    }

    @Test
    fun `lock and port errors reach the relay service`() {
        val store = LogStore()
        store.applyLines(listOf("INFO fine"))
        assertFalse(RelayForegroundService.isLocked.value)
        store.applyLines(listOf("ERROR Cannot acquire directory lock on \"/data/db\""))
        assertTrue(RelayForegroundService.isLocked.value)
        assertFalse(RelayForegroundService.isPortConflict.value)
        store.applyLines(listOf("listen tcp :3355: bind: address already in use"))
        assertTrue(RelayForegroundService.isLocked.value)
        assertTrue(RelayForegroundService.isPortConflict.value)
    }

    @Test
    fun `the console keeps the newest 500 lines`() {
        val store = LogStore()
        store.applyLines((1..600).map { "INFO line $it" })
        assertEquals(500, store.logs.value.size)
        assertEquals("line 600", store.logs.value.last().message)
    }
}
