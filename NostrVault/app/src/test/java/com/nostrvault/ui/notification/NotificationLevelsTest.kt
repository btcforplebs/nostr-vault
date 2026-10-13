package com.nostrvault.ui.notification

import com.nostrvault.ui.components.FilterNote
import com.nostrvault.ui.theme.NostrVaultIcons
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** The manager's side of docs/pills.md: levels, lifetimes, and feedback that never stacks. */
@OptIn(ExperimentalCoroutinesApi::class)
class NotificationLevelsTest {

    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    @Test fun errorStaysUntilTappedWarningTimesOut() = runTest(dispatcher) {
        val manager = NotificationManager()
        manager.showError("Like failed")
        manager.showError("Slow relay", ErrorStyle.WARNING)
        assertEquals(2, manager.notifications.value.size)
        assertTrue(manager.notifications.value.all { it.level == PillLevel.ERROR })

        advanceTimeBy(5_001)
        val left = manager.notifications.value.single() as ErrorNotification
        assertEquals("Like failed", left.message)
        assertEquals(0L, left.autoDismissMs)

        manager.dismiss(left.id)
        assertTrue(manager.notifications.value.isEmpty())
    }

    @Test fun feedbackReplacesFeedbackAndLeavesResultsAlone() = runTest(dispatcher) {
        val manager = NotificationManager()
        manager.showToast("Saved to gallery")
        manager.showFeedback("Link copied")
        manager.showFeedback("Text copied", NostrVaultIcons.Copy)
        val feedback = manager.notifications.value.filterIsInstance<FeedbackNotification>()
        assertEquals(listOf("Text copied"), feedback.map { it.message })
        assertEquals(1, manager.notifications.value.filterIsInstance<ActionToast>().size)

        // Feedback is 2 s, a result 3 s.
        advanceTimeBy(2_001)
        assertTrue(manager.notifications.value.none { it.level == PillLevel.FEEDBACK })
        assertEquals(1, manager.notifications.value.size)
        advanceTimeBy(1_000)
        assertTrue(manager.notifications.value.isEmpty())
    }

    @Test fun filterNoteIsFeedbackAndALateUpdateCannotBringItBack() = runTest(dispatcher) {
        val manager = NotificationManager()
        val note = FilterNote(NostrVaultIcons.At, "Mentions", "on")
        manager.showFilterNote("fn", note)
        assertTrue(manager.isShowing("fn"))
        manager.showFeedback("Liked")
        assertFalse(manager.isShowing("fn"))

        manager.updateFilterNote("fn", note.copy(detail = "on · 18"))
        assertFalse(manager.isShowing("fn"))
        assertEquals(listOf("Liked"), manager.notifications.value.filterIsInstance<FeedbackNotification>().map { it.message })
    }

    @Test fun zappingReportsThroughOneZapPill() = runTest(dispatcher) {
        val manager = NotificationManager()
        val result = manager.zapping("Alice", 21) { Result.success(Unit) }
        assertTrue(result.isSuccess)
        val pill = manager.notifications.value.single() as ZapNotification
        assertEquals(ZapStatus.SUCCESS, pill.status)
        assertEquals(PillLevel.RESULT, pill.level)

        manager.zapping("Bob", 21) { Result.failure<Unit>(IllegalStateException("No wallet")) }
        val failed = manager.notifications.value.first() as ZapNotification
        assertEquals(ZapStatus.FAILED("No wallet"), failed.status)
        assertEquals(PillLevel.ERROR, failed.level)
    }
}
