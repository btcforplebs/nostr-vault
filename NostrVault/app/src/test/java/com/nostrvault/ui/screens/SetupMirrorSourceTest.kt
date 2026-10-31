package com.nostrvault.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SetupMirrorSourceTest {

    @Test
    fun `the suggestion is not added over their own list`() {
        assertNull(SetupMirrorSource.mirrors(listOf("https://theirs.example"), SUGGESTED_MIRROR_SOURCE))
    }

    @Test
    fun `the suggestion is used when they have none`() {
        assertEquals(listOf(SUGGESTED_MIRROR_SOURCE), SetupMirrorSource.mirrors(emptyList(), SUGGESTED_MIRROR_SOURCE))
    }

    @Test
    fun `a server they typed goes after theirs, once`() {
        assertEquals(
            listOf("https://theirs.example", "https://typed.example"),
            SetupMirrorSource.mirrors(listOf("https://theirs.example"), " https://typed.example "),
        )
        assertNull(SetupMirrorSource.mirrors(listOf("https://theirs.example"), "https://Theirs.example/"))
        assertNull(SetupMirrorSource.mirrors(listOf("https://theirs.example"), "  "))
    }
}
