package com.nostrvault.ui.screens.profile

import com.nostrvault.ui.screens.profile.ProfileOlderPage.Outcome
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

class ProfileOlderPageTest {

    /** A list the page fills, and the page, as the view model wires them. */
    private class Harness {
        val page = ProfileOlderPage()
        var size = 50
        fun note() { size++; page.onArrival() }
        fun eose(subId: String = SUB) = page.onEose(subId)
        suspend fun await(relays: Int) = page.await(SUB, relays, 50, { size })
    }

    private fun TestScope.at(ms: Long, block: () -> Unit) = launch { delay(ms); block() }

    @Test fun aPageWithNewNotesEndsWhenTheRelayAnswers() = runTest {
        val h = Harness()
        at(200) { h.note() }
        at(400) { h.eose() }
        assertEquals(Outcome.GREW, h.await(relays = 3))
        assertEquals(400, currentTime)
    }

    @Test fun anEmptyAnswerEndsPagingOnceEveryRelayHasAnswered() = runTest {
        val h = Harness()
        at(100) { h.eose() }
        at(300) { h.eose() }
        at(2_500) { h.eose() }
        assertEquals(Outcome.EMPTY, h.await(relays = 3))
        assertEquals(2_500, currentTime)
    }

    /** Ted's case: the local relay answers empty at once, a remote note comes at 2 s. */
    @Test fun aFastEmptyRelayDoesNotEndPagingBeforeASlowOneAnswers() = runTest {
        val h = Harness()
        at(50) { h.eose() }
        at(2_000) { h.note() }
        at(2_100) { h.eose() }
        assertEquals(Outcome.GREW, h.await(relays = 2))
        assertEquals(2_000, currentTime)
    }

    /** The old fixed 5 s wait called this page "nothing older left". */
    @Test fun aSlowRelayIsNotNothingOlder() = runTest {
        val h = Harness()
        at(7_000) { h.note() }
        at(7_200) { h.eose() }
        assertEquals(Outcome.GREW, h.await(relays = 1))
        assertEquals(7_200, currentTime)
    }

    @Test fun noAnswerAtAllTimesOutWithoutEndingPaging() = runTest {
        val h = Harness()
        assertEquals(Outcome.TIMED_OUT, h.await(relays = 2))
        assertEquals(ProfileOlderPage.TIMEOUT_MS, currentTime)
    }

    /** One relay never answers: the others' empty answers don't end paging. */
    @Test fun aRelayThatNeverAnswersLeavesPagingOpen() = runTest {
        val h = Harness()
        at(100) { h.eose() }
        at(200) { h.eose() }
        assertEquals(Outcome.TIMED_OUT, h.await(relays = 3))
        assertEquals(ProfileOlderPage.TIMEOUT_MS, currentTime)
    }

    /** Notes that land with no EOSE from anyone still count when time is up. */
    @Test fun notesWithNoEoseStillGrowThePageAtTheTimeout() = runTest {
        val h = Harness()
        at(3_000) { h.note() }
        assertEquals(Outcome.GREW, h.await(relays = 2))
        assertEquals(ProfileOlderPage.TIMEOUT_MS, currentTime)
    }

    /** A late EOSE from an earlier page, or another kind of REQ, is not this page's answer. */
    @Test fun onlyItsOwnSubIdAnswersThePage() = runTest {
        val h = Harness()
        at(50) { h.eose("older-0ld000"); h.eose("older-tagged-abc123"); h.eose("profile-abc123") }
        at(2_000) { h.note() }
        at(2_100) { h.eose() }
        assertEquals(Outcome.GREW, h.await(relays = 1))
        assertEquals(2_100, currentTime)
    }

    @Test fun noRelayTookTheReqSoNothingOlderIsNotDecided() = runTest {
        val h = Harness()
        assertEquals(Outcome.TIMED_OUT, h.await(relays = 0))
        assertEquals(0, currentTime)
    }

    private companion object {
        const val SUB = "older-abc123"
    }
}
