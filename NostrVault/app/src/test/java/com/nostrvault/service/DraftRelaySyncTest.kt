package com.nostrvault.service

import android.content.Context
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.Draft
import com.nostrvault.data.model.DraftEvents
import com.nostrvault.relay.HavenConfig
import com.nostrvault.relay.RelayForegroundService
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Typing saves a draft on the device only; the relay copy (a signed kind
 * 31234, an Amber prompt on a remote signer) goes once, when asked.
 */
class DraftRelaySyncTest {

    @get:Rule val tmp = TemporaryFolder()

    private val nostr = mockk<NostrService>(relaxed = true)

    /**
     * The relay is up before the service starts, and the service's own
     * relay-up pass (flush the queue, then fetch) has finished before a test
     * saves anything. Raising the relay after the service was built raced
     * that pass against the test's saves: a draft saved first was flushed,
     * a sign the test never asked for.
     */
    private fun service(): DraftService {
        val context = mockk<Context>(relaxed = true)
        every { context.filesDir } returns tmp.root
        val config = mockk<ConfigStore>(relaxed = true)
        every { config.activeAccountHexPubkey } returns MutableStateFlow("alice")
        // Nothing reads the config while the service is built; the first
        // read is the relay-up pass's fetch, which runs after its flush.
        val passDone = CountDownLatch(1)
        val configFlow = MutableStateFlow(HavenConfig())
        every { config.config } answers {
            passDone.countDown()
            configFlow
        }
        RelayForegroundService._readyForConnections.value = true
        val drafts = DraftService(context, config, nostr)
        check(passDone.await(5, TimeUnit.SECONDS)) { "relay-up pass never ran" }
        return drafts
    }

    @After fun relayDown() {
        RelayForegroundService._readyForConnections.value = false
    }

    private fun draftSigns(times: Int) = coVerify(exactly = times, timeout = 1_000) {
        nostr.signEventAsync(DraftEvents.KIND, any(), any(), any(), any(), any(), any(), any())
    }

    @Test fun typingDoesNotSign() {
        val drafts = service()
        drafts.saveDraft(Draft(id = "d", content = "H"), syncToRelay = false)
        drafts.saveDraft(Draft(id = "d", content = "He"), syncToRelay = false)
        drafts.saveDraft(Draft(id = "d", content = "Hello"), syncToRelay = false)
        Thread.sleep(200)
        draftSigns(0)
    }

    @Test fun leavingSignsOnce() {
        val drafts = service()
        drafts.saveDraft(Draft(id = "d", content = "Hello"), syncToRelay = false)
        drafts.syncDraft("d")
        draftSigns(1)
    }

    /** Backgrounded, then left before the first sign came back: still one sign. */
    @Test fun aSecondAskWhileTheFirstIsOutDoesNotSignAgain() = runBlocking {
        val gate = CompletableDeferred<Unit>()
        coEvery { nostr.signEventAsync(DraftEvents.KIND, any(), any(), any(), any(), any(), any(), any()) } coAnswers {
            gate.await(); null
        }
        val drafts = service()
        drafts.saveDraft(Draft(id = "d", content = "Hello"), syncToRelay = false)
        drafts.syncDraft("d")
        drafts.syncDraft("d")
        draftSigns(1)
        gate.complete(Unit)
        Unit
    }

    @Test fun aDeletedDraftIsNotSynced() {
        val drafts = service()
        drafts.saveDraft(Draft(id = "d", content = "Hello"), syncToRelay = false)
        drafts.deleteDraft("d")
        drafts.syncDraft("d")
        Thread.sleep(200)
        draftSigns(0)
    }

    @Test fun anUnqueuedDraftIsNotSynced() {
        val drafts = service()
        drafts.syncDraft("nothing")
        Thread.sleep(200)
        draftSigns(0)
    }
}
