package com.nostrvault.ui.components

import com.nostrvault.ui.theme.NostrVaultIcons
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Vault's filter notes read as iOS `filterNoteText` / `noteFilterTap`. */
class VaultFilterNoteTest {
    @Test fun `a count reads name, on, count`() {
        val note = countNote(NostrVaultIcons.At, "Mentions", 18, capped = false)
        assertEquals("Mentions · on · 18", note.text)
        assertEquals("Mentions", note.title)
        assertFalse(note.dimmed)
    }

    @Test fun `none yet rather than a zero`() {
        assertEquals("Likes given · on · none yet", countNote(NostrVaultIcons.Given, "Likes given", 0, capped = false).text)
        // A capped empty list is still empty.
        assertEquals("none yet", countTally(0, capped = true))
    }

    @Test fun `a list stopped at its page size says plus`() {
        assertEquals("Everything · on · 500+", countNote(NostrVaultIcons.Layers, "Everything", 500, capped = true).text)
        assertEquals("18+", countTally(18, capped = true))
        assertEquals("18", countTally(18, capped = false))
    }

    @Test fun `a pick still counting says on`() {
        assertEquals("All notes · on", pickedNote(NostrVaultIcons.Layers, "All notes").text)
    }

    @Test fun `recipes turned off is dimmed with its own icon`() {
        val note = FilterNote.off("Recipes only", NostrVaultIcons.Recipes)
        assertEquals("Recipes only · off", note.text)
        assertTrue(note.dimmed)
        assertEquals(NostrVaultIcons.Recipes, note.icon)
    }
}
