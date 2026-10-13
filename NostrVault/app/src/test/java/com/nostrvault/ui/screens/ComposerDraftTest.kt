package com.nostrvault.ui.screens

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * Article, recipe and poll drafts: what counts as worth keeping, the store on
 * disk, and the keeper that autosaves, finishes and discards. Twin of iOS
 * ComposerDraft / ComposerDraftStore / ComposerDraftKeeper.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ComposerDraftTest {

    @get:Rule val tmp = TemporaryFolder()

    private val article = ComposerDraft.Kind.ARTICLE

    private fun store(dir: File = File(tmp.root, "drafts")) = ComposerDraftStore(dir)

    private fun photo(name: String = "pick.img", bytes: String = "jpeg-bytes"): File =
        tmp.newFile(name).apply { writeText(bytes) }

    // ── The model ────────────────────────────────────────────────────────

    @Test fun anOpenedFormIsNotADraft() {
        assertFalse(ComposerDraft(article).hasContent)
        assertFalse(ComposerDraft(ComposerDraft.Kind.RECIPE).hasContent)
        // A new poll has two empty options and a closing choice: still nothing.
        val poll = ComposerDraft(ComposerDraft.Kind.POLL, closing = PollClosing.ONE_WEEK.name)
        assertEquals(listOf("", ""), poll.options)
        assertFalse(poll.hasContent)
    }

    @Test fun anyTypedFieldOrACoverIsADraft() {
        assertTrue(ComposerDraft(article, summary = "x").hasContent)
        assertTrue(ComposerDraft(ComposerDraft.Kind.RECIPE, directions = "Boil").hasContent)
        assertTrue(ComposerDraft(ComposerDraft.Kind.POLL, options = listOf("", "Yes")).hasContent)
        assertTrue(ComposerDraft(article, hasCover = true).hasContent)
        assertFalse(ComposerDraft(article, title = "   \n").hasContent)
    }

    @Test fun previewsFallBackAndShorten() {
        assertEquals("Untitled", ComposerDraft(article).previewTitle)
        assertEquals("Untitled poll", ComposerDraft(ComposerDraft.Kind.POLL).previewTitle)
        assertEquals("Red · Blue", ComposerDraft(ComposerDraft.Kind.POLL, options = listOf(" Red ", "", "Blue")).previewDetail)
        assertEquals("one two", ComposerDraft(article, body = "one\ntwo").previewDetail)
        val long = ComposerDraft(article, body = "a".repeat(150)).previewDetail
        assertEquals(101, long.length)
        assertTrue(long.endsWith("…"))
    }

    // ── The store ────────────────────────────────────────────────────────

    @Test fun savesPerAccountAndReadsBackAfterARestart() {
        store().save(ComposerDraft(article, id = "a1", title = "Mine", updatedAt = 1), null, "alice")
        store().save(ComposerDraft(article, id = "b1", title = "Theirs", updatedAt = 1), null, "bob")

        val fresh = store()
        assertEquals(listOf("Mine"), fresh.drafts(article, "alice").map { it.title })
        assertEquals(listOf("Theirs"), fresh.drafts(article, "bob").map { it.title })
        assertTrue(fresh.drafts(ComposerDraft.Kind.RECIPE, "alice").isEmpty())
    }

    @Test fun newestFirst() {
        val s = store()
        s.save(ComposerDraft(article, id = "old", title = "Old", updatedAt = 1), null, "a")
        s.save(ComposerDraft(article, id = "new", title = "New", updatedAt = 2), null, "a")
        assertEquals(listOf("New", "Old"), s.drafts(article, "a").map { it.title })
    }

    @Test fun clearingEveryFieldDeletesTheDraft() {
        val s = store()
        s.save(ComposerDraft(article, id = "d", title = "Soon empty"), null, "a")
        s.save(ComposerDraft(article, id = "d"), null, "a")
        assertTrue(s.drafts(article, "a").isEmpty())
    }

    @Test fun coverIsCopiedInAndGoesWithTheDraft() {
        val s = store()
        val picked = photo()
        s.save(ComposerDraft(article, id = "d", coverMime = "image/png"), picked, "a")
        picked.delete() // the picker's copy goes; the draft keeps its own

        val saved = s.drafts(article, "a").single()
        assertTrue(saved.hasCover)
        assertEquals("image/png", saved.coverMime)
        assertEquals("jpeg-bytes", s.cover(saved, "a")!!.readText())

        // Saving again with its own cover file keeps it in place.
        s.save(saved.copy(title = "t"), s.cover(saved, "a"), "a")
        assertEquals("jpeg-bytes", s.cover(s.draft("d", "a")!!, "a")!!.readText())

        s.delete("d", "a")
        assertFalse(s.coverFile("d", "a").exists())
    }

    @Test fun removingTheCoverForgetsItsType() {
        val s = store()
        s.save(ComposerDraft(article, id = "d", title = "t", coverMime = "image/png"), photo(), "a")
        s.save(ComposerDraft(article, id = "d", title = "t", coverMime = "image/png"), null, "a")
        val saved = s.draft("d", "a")!!
        assertFalse(saved.hasCover)
        assertNull(saved.coverMime)
        assertNull(s.cover(saved, "a"))
    }

    @Test fun aDamagedFileReadsAsNoDrafts() {
        val dir = File(tmp.root, "drafts").apply { mkdirs() }
        store(dir).listFile("a").writeText("{not json")
        assertTrue(store(dir).drafts(article, "a").isEmpty())
    }

    // ── The keeper ───────────────────────────────────────────────────────

    private fun TestScope.keeper(s: ComposerDraftStore, kind: ComposerDraft.Kind = article) =
        ComposerDraftKeeper(kind, "a", s, this, now = { testScheduler.currentTime + 1 })

    @Test fun typingSavesOnceAfterAPause() = kotlinx.coroutines.test.runTest(StandardTestDispatcher()) {
        val s = store()
        val k = keeper(s)
        k.changed(ComposerDraft(article, title = "H"), null)
        advanceTimeBy(400)
        k.changed(ComposerDraft(article, title = "Hello"), null)
        advanceTimeBy(ComposerDraftKeeper.AUTOSAVE_DELAY_MS - 1)
        runCurrent()
        assertTrue("saved before the pause ended", s.drafts(article, "a").isEmpty())
        advanceTimeBy(2)
        runCurrent()
        assertEquals(listOf("Hello"), s.drafts(article, "a").map { it.title })
    }

    @Test fun oneSessionIsOneDraft() = kotlinx.coroutines.test.runTest(StandardTestDispatcher()) {
        val s = store()
        val k = keeper(s)
        k.saveNow(ComposerDraft(article, title = "One"), null)
        k.saveNow(ComposerDraft(article, title = "One more"), null)
        assertEquals(listOf("One more"), s.drafts(article, "a").map { it.title })
    }

    @Test fun anEmptyFormSavesNothing() = kotlinx.coroutines.test.runTest(StandardTestDispatcher()) {
        val s = store()
        keeper(s).saveNow(ComposerDraft(article), null)
        assertFalse(File(tmp.root, "drafts").exists())
    }

    @Test fun publishingDropsTheDraftAndLateSavesCannotBringItBack() =
        kotlinx.coroutines.test.runTest(StandardTestDispatcher()) {
            val s = store()
            val k = keeper(s)
            k.saveNow(ComposerDraft(article, title = "Posted"), null)
            k.changed(ComposerDraft(article, title = "Posted!"), null)
            k.finish()
            advanceTimeBy(ComposerDraftKeeper.AUTOSAVE_DELAY_MS * 2)
            runCurrent()
            // The screen's leave-save runs after publish too.
            k.saveNow(ComposerDraft(article, title = "Posted!"), null)
            assertTrue(s.drafts(article, "a").isEmpty())
        }

    @Test fun discardOnANewDraftDeletesIt() = kotlinx.coroutines.test.runTest(StandardTestDispatcher()) {
        val s = store()
        val k = keeper(s)
        k.saveNow(ComposerDraft(article, title = "Never mind"), null)
        k.discard()
        assertTrue(s.drafts(article, "a").isEmpty())
    }

    @Test fun discardOnAnOpenedDraftPutsItBack() = kotlinx.coroutines.test.runTest(StandardTestDispatcher()) {
        val s = store()
        s.save(ComposerDraft(article, id = "keep", title = "Original", updatedAt = 5), photo(bytes = "old"), "a")
        val k = keeper(s)
        val saved = k.others.value.single()

        val cover = k.open(saved)
        assertNotNull(cover)
        assertTrue(k.editsSavedDraft)
        // Edits, with a new cover, are autosaved over it...
        k.saveNow(saved.copy(title = "Edited"), photo("new.img", "new"))
        assertEquals("Edited", s.draft("keep", "a")!!.title)
        assertEquals("new", s.cover(s.draft("keep", "a")!!, "a")!!.readText())

        // Opening it left no copy on disk that Save Draft would strand.
        assertEquals(setOf("composer_drafts_a.json", "cover_a_keep"),
            File(tmp.root, "drafts").list()!!.toSet())

        // ...and Discard Changes restores both.
        k.discard()
        val back = s.draft("keep", "a")!!
        assertEquals("Original", back.title)
        assertEquals("old", s.cover(back, "a")!!.readText())
    }

    @Test fun theListLeavesOutTheDraftBeingEdited() = kotlinx.coroutines.test.runTest(StandardTestDispatcher()) {
        val s = store()
        s.save(ComposerDraft(article, id = "x", title = "X"), null, "a")
        s.save(ComposerDraft(article, id = "y", title = "Y"), null, "a")
        val k = keeper(s)
        assertEquals(2, k.others.value.size)
        k.open(k.others.value.first { it.id == "x" })
        assertEquals(listOf("y"), k.others.value.map { it.id })
        k.delete(k.others.value.single())
        assertTrue(k.others.value.isEmpty())
        assertTrue(s.draft("y", "a") == null)
    }

    @Test fun openingAnotherDraftKeepsTheCurrentWork() = kotlinx.coroutines.test.runTest(StandardTestDispatcher()) {
        val s = store()
        s.save(ComposerDraft(article, id = "older", title = "Older"), null, "a")
        val k = keeper(s)
        // What the composer does before loading a picked draft.
        k.saveNow(ComposerDraft(article, title = "In progress"), null)
        k.open(s.draft("older", "a")!!)
        assertEquals(setOf("Older", "In progress"), s.drafts(article, "a").map { it.title }.toSet())
    }
}
