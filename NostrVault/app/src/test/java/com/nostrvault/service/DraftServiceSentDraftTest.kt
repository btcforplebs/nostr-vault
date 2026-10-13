package com.nostrvault.service

import android.content.Context
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.Draft
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * A post that goes out deletes the draft it was sent from, but not edits
 * made to that draft (reopened from Drafts) while the post was still sending.
 */
class DraftServiceSentDraftTest {

    @get:Rule val tmp = TemporaryFolder()

    private fun service(): DraftService {
        val context = mockk<Context>(relaxed = true)
        every { context.filesDir } returns tmp.root
        val config = mockk<ConfigStore>(relaxed = true)
        every { config.activeAccountHexPubkey } returns MutableStateFlow("alice")
        return DraftService(context, config, mockk(relaxed = true))
    }

    @Test fun theSentVersionGoes() {
        val drafts = service()
        val sent = drafts.saveDraft(Draft(id = "d", content = "Hello"))
        drafts.deleteSentDraft("d", sent.updatedAt)
        assertNull(drafts.findDraft("d"))
    }

    @Test fun editsMadeWhileItWasSendingStay() {
        val drafts = service()
        val sent = drafts.saveDraft(Draft(id = "d", content = "Hello"))
        Thread.sleep(5)
        drafts.saveDraft(Draft(id = "d", content = "Hello, edited"))
        drafts.deleteSentDraft("d", sent.updatedAt)
        assertEquals("Hello, edited", drafts.findDraft("d")?.content)
    }

    @Test fun noRecordedVersionDeletesWhateverIsThere() {
        val drafts = service()
        drafts.saveDraft(Draft(id = "d", content = "Hello"))
        drafts.deleteSentDraft("d", null)
        assertNull(drafts.findDraft("d"))
    }
}
