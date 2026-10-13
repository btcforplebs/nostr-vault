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
    private class Harness(tagged: Boolean = false) {
        val page = ProfileOlderPage(tagged)
        var size = 50
        fun note() { size++; page.onArrival() }
    }

    private fun TestScope.at(ms: Long, block: () -> Unit) = launch { delay(ms); block() }

    @Test fun aPageWithNewNotesEndsWhenTheRelayAnswers() = runTest {
        val h = Harness()
        at(200) { h.note() }
        at(400) { h.page.onEose("older-abc123") }
        assertEquals(Outcome.GREW, h.page.await(50, { h.size }))
        assertEquals(400, currentTime)
    }

    @Test fun anEmptyAnswerEndsPagingSoonAfterTheRelaysGoQuiet() = runTest {
        val h = Harness()
        at(300) { h.page.onEose("older-abc123") }
        assertEquals(Outcome.EMPTY, h.page.await(50, { h.size }))
        assertEquals(300 + ProfileOlderPage.SETTLE_MS, currentTime)
    }

    /** The old fixed 5 s wait called this page "nothing older left". */
    @Test fun aSlowRelayIsNotNothingOlder() = runTest {
        val h = Harness()
        at(7_000) { h.note() }
        at(7_200) { h.page.onEose("older-abc123") }
        assertEquals(Outcome.GREW, h.page.await(50, { h.size }))
        assertEquals(7_200, currentTime)
    }

    @Test fun noAnswerAtAllTimesOutWithoutEndingPaging() = runTest {
        val h = Harness()
        assertEquals(Outcome.TIMED_OUT, h.page.await(50, { h.size }))
        assertEquals(ProfileOlderPage.TIMEOUT_MS, currentTime)
    }

    @Test fun aSecondRelayStillLandsAfterTheFirstAnswersEmpty() = runTest {
        val h = Harness()
        at(200) { h.page.onEose("older-abc123") }
        at(1_000) { h.note() }
        at(1_100) { h.page.onEose("older-abc123") }
        assertEquals(Outcome.GREW, h.page.await(50, { h.size }))
        assertEquals(1_000, currentTime)
    }

    @Test fun onlyItsOwnKindOfEoseAnswersThePage() = runTest {
        val notes = Harness(tagged = false)
        at(100) { notes.page.onEose("older-tagged-abc123"); notes.page.onEose("profile-abc123") }
        assertEquals(Outcome.TIMED_OUT, notes.page.await(50, { notes.size }))

        val tagged = Harness(tagged = true)
        launch { delay(100); tagged.page.onEose("older-abc123"); delay(100); tagged.page.onEose("older-tagged-abc123") }
        val start = currentTime
        assertEquals(Outcome.EMPTY, tagged.page.await(50, { tagged.size }))
        assertEquals(200 + ProfileOlderPage.SETTLE_MS, currentTime - start)
    }
}
