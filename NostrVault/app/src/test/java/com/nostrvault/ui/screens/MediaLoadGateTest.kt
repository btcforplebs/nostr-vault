package com.nostrvault.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaLoadGateTest {
    private fun item(sha: String) = BlossomMediaItem(
        sha256 = sha, displayUrl = "https://x/$sha", localFile = null, mimeType = "image/jpeg",
        size = null, uploaded = null, lastModified = null, isLocal = false,
    )

    @Test
    fun slowLoadFromBeforeADeleteCannotBringTheTileBack() {
        val gate = MediaLoadGate()
        val slow = gate.begin()        // refresh; mirror lists still on their way
        gate.removed("bb")             // the file is deleted meanwhile
        // The slow load's server lists were read before the delete.
        val shown = gate.result(slow, listOf(item("aa"), item("bb")))
        assertEquals(listOf("aa"), shown?.map { it.sha256 })
    }

    @Test
    fun onlyTheNewestLoadPublishes() {
        val gate = MediaLoadGate()
        val first = gate.begin()
        val second = gate.begin()
        assertNull(gate.result(first, listOf(item("aa"), item("bb"))))
        assertFalse(gate.isCurrent(first))
        assertTrue(gate.isCurrent(second))
        assertEquals(listOf("aa"), gate.result(second, listOf(item("aa")))?.map { it.sha256 })
    }

    @Test
    fun loadStartedAfterTheRemovalStillShowsAServerCopy() {
        val gate = MediaLoadGate()
        gate.begin()
        gate.removed("BB")
        val reload = gate.begin()      // the reload after the delete: a server kept the file
        assertEquals(listOf("bb"), gate.result(reload, listOf(item("bb")))?.map { it.sha256 })
    }
}
