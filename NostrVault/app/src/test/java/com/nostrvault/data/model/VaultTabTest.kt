package com.nostrvault.data.model

import com.nostrvault.ui.navigation.NotificationTarget
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Vault tab's pure logic (iOS VaultNoteScopeTests, #443). */
class VaultTabTest {
    /** The relay tab's note kinds as DashboardViewModel lists them. */
    private val all = setOf(1, 6, 30023, 1111, 9802, 1068)

    // ── Note scopes ───────────────────────────────────────────────

    @Test fun `notes leave out articles and highlights`() {
        assertEquals(setOf(1, 6, 1111, 1068), VaultNoteScope.NOTES.kinds(all))
    }

    @Test fun `articles and highlights are one kind each`() {
        assertEquals(setOf(30023), VaultNoteScope.ARTICLES.kinds(all))
        assertEquals(setOf(9802), VaultNoteScope.HIGHLIGHTS.kinds(all))
    }

    @Test fun `every kind lands in exactly one scope`() {
        val scopes = VaultNoteScope.entries.map { it.kinds(all) }
        assertEquals(all, scopes.flatten().toSet())
        assertEquals(all.size, scopes.sumOf { it.size })
    }

    @Test fun `only articles and highlights page by button`() {
        assertFalse(VaultNoteScope.NOTES.pagesByButton)
        assertTrue(VaultNoteScope.ARTICLES.pagesByButton)
        assertTrue(VaultNoteScope.HIGHLIGHTS.pagesByButton)
    }

    @Test fun `recipe tags match case-insensitively and only as t tags`() {
        assertTrue(VaultNoteScope.isRecipe(listOf(listOf("t", "ZapCooking"))))
        assertTrue(VaultNoteScope.isRecipe(listOf(listOf("d", "x"), listOf("t", "nostrcooking"))))
        assertFalse(VaultNoteScope.isRecipe(listOf(listOf("t", "cooking"))))
        assertFalse(VaultNoteScope.isRecipe(listOf(listOf("p", "zapcooking"))))
        assertFalse(VaultNoteScope.isRecipe(listOf(listOf("t"))))
        assertFalse(VaultNoteScope.isRecipe(emptyList()))
    }

    /** The app's recipe feed and the Vault's Recipes filter must agree. */
    @Test fun `recipe topics match the recipe feed`() {
        assertEquals(setOf("zapcooking", "nostrcooking"), VaultNoteScope.RECIPE_TOPICS)
    }

    @Test fun `a post's kind picks the list that holds it`() {
        assertEquals(VaultNoteScope.ARTICLES, VaultNoteScope.forKind(30023))
        assertEquals(VaultNoteScope.HIGHLIGHTS, VaultNoteScope.forKind(9802))
        assertEquals(VaultNoteScope.NOTES, VaultNoteScope.forKind(1))
        assertEquals(VaultNoteScope.NOTES, VaultNoteScope.forKind(null))
    }

    // ── Modes ─────────────────────────────────────────────────────

    @Test fun `the menu lists the modes in order and zaps only hides likes`() {
        assertEquals(
            listOf("Notes", "Articles", "Highlights", "Media", "Likes", "Zaps", "Followers"),
            VaultMode.menu(zapsOnly = false).map { it.displayName },
        )
        assertFalse(VaultMode.LIKES in VaultMode.menu(zapsOnly = true))
        assertEquals(6, VaultMode.menu(zapsOnly = true).size)
    }

    @Test fun `the pill names what the tab shows`() {
        assertEquals(VaultMode.MEDIA, VaultMode.of(true, VaultViewMode.LIKES, VaultNoteScope.NOTES))
        assertEquals(VaultMode.ARTICLES, VaultMode.of(false, VaultViewMode.NOTES, VaultNoteScope.ARTICLES))
        assertEquals(VaultMode.HIGHLIGHTS, VaultMode.of(false, VaultViewMode.NOTES, VaultNoteScope.HIGHLIGHTS))
        assertEquals(VaultMode.NOTES, VaultMode.of(false, VaultViewMode.NOTES, VaultNoteScope.NOTES))
        // A scope left over from Articles doesn't rename Zaps.
        assertEquals(VaultMode.ZAPS, VaultMode.of(false, VaultViewMode.ZAPS, VaultNoteScope.ARTICLES))
    }

    @Test fun `each mode maps back to its list and scope`() {
        for (mode in VaultMode.entries) {
            if (mode == VaultMode.MEDIA) {
                assertNull(mode.viewMode)
                continue
            }
            val back = VaultMode.of(false, mode.viewMode!!, mode.noteScope ?: VaultNoteScope.NOTES)
            assertEquals(mode, back)
        }
    }

    // ── New-activity dots ─────────────────────────────────────────

    @Test fun `the dot shows only for news in another mode`() {
        val news = setOf(VaultMode.FOLLOWERS)
        assertTrue(VaultDots.hasNewElsewhere(news, VaultMode.NOTES))
        assertTrue(VaultDots.hasNewElsewhere(news, VaultMode.MEDIA))
        assertFalse(VaultDots.hasNewElsewhere(news, VaultMode.FOLLOWERS))
        assertFalse(VaultDots.hasNewElsewhere(emptySet(), VaultMode.NOTES))
        assertTrue(VaultDots.hasNewElsewhere(setOf(VaultMode.FOLLOWERS, VaultMode.NOTES), VaultMode.FOLLOWERS))
    }

    @Test fun `nothing is in sight on Media, Articles or Highlights`() {
        // Followers stays the relay half's list while Media shows, but you can't see it.
        assertNull(VaultDots.watchedMode(true, VaultViewMode.FOLLOWERS, VaultNoteScope.NOTES))
        assertNull(VaultDots.watchedMode(false, VaultViewMode.NOTES, VaultNoteScope.ARTICLES))
        assertNull(VaultDots.watchedMode(false, VaultViewMode.NOTES, VaultNoteScope.HIGHLIGHTS))
        assertEquals(VaultViewMode.NOTES, VaultDots.watchedMode(false, VaultViewMode.NOTES, VaultNoteScope.NOTES))
        assertEquals(VaultViewMode.FOLLOWERS, VaultDots.watchedMode(false, VaultViewMode.FOLLOWERS, VaultNoteScope.ARTICLES))
    }

    // ── Load older ────────────────────────────────────────────────

    @Test fun `the first page starts just older than the oldest loaded`() {
        assertEquals(VaultPageCursor(until = 99), VaultPageCursor.start(listOf(300, 100, 200), nowSeconds = 1_000))
        assertEquals(VaultPageCursor(until = 1_000), VaultPageCursor.start(emptyList(), nowSeconds = 1_000))
    }

    @Test fun `each page moves the cursor past its oldest event`() {
        val next = VaultPageCursor(until = 500).after(listOf(450, 320, 410))
        assertEquals(VaultPageCursor(until = 319), next)
        assertFalse(next.done)
    }

    @Test fun `an empty page ends paging where it was`() {
        val done = VaultPageCursor(until = 319).after(emptyList())
        assertTrue(done.done)
        assertEquals(319, done.until)
    }

    @Test fun `a page with something newer than asked never moves the cursor forward`() {
        // A relay ignoring `until` must not send the same page round again.
        assertEquals(VaultPageCursor(until = 319), VaultPageCursor(until = 319).after(listOf(900)))
    }

    // ── Notification routing ──────────────────────────────────────

    @Test fun `a notification lands on the mode that holds its event`() {
        assertEquals(VaultMode.ARTICLES, NotificationTarget.vaultModeFor("mention", 30023, zapsOnly = false))
        assertEquals(VaultMode.HIGHLIGHTS, NotificationTarget.vaultModeFor("mention", 9802, zapsOnly = false))
        assertEquals(VaultMode.NOTES, NotificationTarget.vaultModeFor("reply", 1, zapsOnly = false))
        assertEquals(VaultMode.NOTES, NotificationTarget.vaultModeFor("repost", 6, zapsOnly = false))
        // Not loaded yet: Notes, until it is.
        assertEquals(VaultMode.NOTES, NotificationTarget.vaultModeFor("mention", null, zapsOnly = false))
    }

    @Test fun `likes, zaps and followers keep their lists whatever the kind`() {
        assertEquals(VaultMode.LIKES, NotificationTarget.vaultModeFor("reaction", 7, zapsOnly = false))
        assertEquals(VaultMode.ZAPS, NotificationTarget.vaultModeFor("zap", 9735, zapsOnly = false))
        assertEquals(VaultMode.FOLLOWERS, NotificationTarget.vaultModeFor(NotificationTarget.FOLLOWERS, null, zapsOnly = false))
        // Zaps Only hides Likes: a like falls back to Notes.
        assertEquals(VaultMode.NOTES, NotificationTarget.vaultModeFor("reaction", 7, zapsOnly = true))
    }
}
