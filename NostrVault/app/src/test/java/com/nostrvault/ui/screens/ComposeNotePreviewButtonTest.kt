package com.nostrvault.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Test

/** One button beside Post (Logen 2026-11-01): Preview shows the note, then reads Edit to go back to typing. */
class ComposeNotePreviewButtonTest {
    @Test fun previewWhileWriting() = assertEquals("Preview", previewButtonLabel(previewing = false))
    @Test fun editWhilePreviewing() = assertEquals("Edit", previewButtonLabel(previewing = true))
}
