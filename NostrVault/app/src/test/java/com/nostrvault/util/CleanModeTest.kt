package com.nostrvault.util

import com.nostrvault.data.model.FeedProfile
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test
import java.io.File

/** Clean mode masks whole listed words as shown, first letter and length kept. */
class CleanModeTest {
    private val list = setOf("fuck", "shit", "ass")

    @After fun off() { CleanMode.enabled = false }

    @Test fun `masks whole words, case kept`() {
        assertEquals("F*** this s***!", CleanMode.mask("Fuck this shit!", list))
        assertEquals("A** and A**-y", CleanMode.mask("Ass and ASS-y", list))
    }

    @Test fun `never inside another word`() {
        val text = "first class, Scunthorpe, assassin, shitake2, fuck3"
        assertSame(text, CleanMode.mask(text, list))
    }

    @Test fun `around punctuation, emoji and other scripts`() {
        assertEquals("(s***)🙂 日本 f***", CleanMode.mask("(shit)🙂 日本 fuck", list))
    }

    @Test fun `shown only while on`() {
        CleanMode.enabled = false
        assertEquals("shit", CleanMode.shown("shit"))
    }

    @Test fun `the asset matches the shared list and parses`() {
        val shared = File("../../docs/clean-words/en.txt").readText()
        val asset = File("src/main/assets/${CleanMode.ASSET}").readText()
        assertEquals(shared, asset)
        val words = CleanMode.parse(asset.lines())
        assertEquals(asset.lines().count { it.isNotBlank() }, words.size)
        assertEquals("F*** you", CleanMode.mask("Fuck you", words))
    }

    @Test fun `profile names keep the raw name for publishing`() {
        val p = FeedProfile(pubkey = "a".repeat(64), displayName = "Shit Poster")
        assertEquals("Shit Poster", p.rawBestName)
        assertEquals("Shit Poster", p.bestName)
    }
}
