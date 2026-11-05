package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** One Import media by itself when the first Moving in finishes; never again, never if it already ran. */
class MediaImportAfterMovingInTest {
    private class Flag : MediaImportAfterMovingInRule.Flag {
        var value = false
        override fun get() = value
        override fun set() { value = true }
    }

    @Test
    fun `the first Moving in starts one Import media, later ones none`() {
        val flag = Flag()
        var runs = 0
        val rule = MediaImportAfterMovingInRule(flag, mediaImportedAt = { null }, runImport = { runs++; true })
        assertTrue(rule.movingInDone())
        assertFalse(rule.movingInDone())
        assertEquals(1, runs)
        assertTrue(flag.value)
    }

    @Test
    fun `no run when Import media already ran here`() {
        var runs = 0
        val rule = MediaImportAfterMovingInRule(Flag(), mediaImportedAt = { 1_700_000_000_000L }, runImport = { runs++; true })
        assertFalse(rule.movingInDone())
        assertEquals(0, runs)
    }

    @Test
    fun `a run already going counts as the one`() {
        val flag = Flag()
        var runs = 0
        val rule = MediaImportAfterMovingInRule(flag, mediaImportedAt = { null }, runImport = { runs++; false })
        assertFalse(rule.movingInDone())
        assertFalse(rule.movingInDone())
        assertEquals(1, runs)
    }
}
