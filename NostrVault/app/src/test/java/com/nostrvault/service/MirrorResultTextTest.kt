package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Test

/** Mirror Now names a server it couldn't reach instead of saying everything is mirrored. */
class MirrorResultTextTest {
    @Test
    fun `nothing new and every server answered`() {
        assertEquals("All media already mirrored", BlossomService.mirrorResultText(0, emptyList()))
    }

    @Test
    fun `an unreachable server is never all mirrored`() {
        assertEquals("Couldn't reach 127.0.0.1", BlossomService.mirrorResultText(0, listOf("127.0.0.1")))
    }

    @Test
    fun `files saved and a server missed`() {
        assertEquals(
            "Mirrored 3 files. Couldn't reach a.example, b.example",
            BlossomService.mirrorResultText(3, listOf("a.example", "b.example", "a.example")),
        )
    }

    @Test
    fun `one file`() {
        assertEquals("Mirrored 1 file", BlossomService.mirrorResultText(1, emptyList()))
    }
}
