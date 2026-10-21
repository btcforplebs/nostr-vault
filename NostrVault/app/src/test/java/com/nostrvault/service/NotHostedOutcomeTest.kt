package com.nostrvault.service

import com.nostrvault.service.BlossomService.PostUploadOutcome
import org.junit.Assert.assertEquals
import org.junit.Test

/** With no media server, a post gets the "set up a media server" path, as on iPhone; never a mesh-only wait (NIP-F1). */
class NotHostedOutcomeTest {
    @Test fun `no media server is NoOutsideServer, whatever home vault there is`() {
        assertEquals(PostUploadOutcome.NoOutsideServer, notHostedOutcome(localOk = true, mirrors = emptyList()))
    }

    @Test fun `servers that did not answer, the post waits for them`() {
        assertEquals(PostUploadOutcome.SavedOnDevice(listOf("https://a.example")), notHostedOutcome(true, listOf("https://a.example")))
    }

    @Test fun `not saved here, nothing can wait`() {
        assertEquals(PostUploadOutcome.NotSavedOnDevice, notHostedOutcome(localOk = false, mirrors = emptyList()))
    }
}
