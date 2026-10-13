package com.nostrvault.ui.notification

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The lane's rule (docs/pills.md): two at most, most important first, feedback replaces, ambient steps aside. */
class PillLaneTest {

    @Test fun showsAtMostTwoMostImportantNewestFirst() {
        val lane = PillLane()
        lane.enter("r1", PillLevel.RESULT)
        lane.enter("r2", PillLevel.RESULT)
        lane.enter("r3", PillLevel.RESULT)
        assertEquals(setOf("r2", "r3"), lane.visible.value)

        lane.enter("e1", PillLevel.ERROR)
        assertEquals(setOf("e1", "r3"), lane.visible.value)
    }

    @Test fun feedbackStepsAsideWhileTwoAboveItShow() {
        val lane = PillLane()
        lane.enter("f", PillLevel.FEEDBACK)
        lane.enter("r1", PillLevel.RESULT)
        assertEquals(setOf("f", "r1"), lane.visible.value)
        lane.enter("r2", PillLevel.RESULT)
        assertEquals(setOf("r1", "r2"), lane.visible.value)
        lane.leave("r1")
        assertEquals(setOf("f", "r2"), lane.visible.value)
    }

    @Test fun newFeedbackReplacesTheOld() {
        val lane = PillLane()
        lane.enter("f1", PillLevel.FEEDBACK)
        lane.enter("f2", PillLevel.FEEDBACK)
        assertEquals(setOf("f2"), lane.visible.value)
        // The old one is gone for good, not just hidden.
        lane.leave("f2")
        assertEquals(emptySet<String>(), lane.visible.value)
    }

    @Test fun ambientShowsOnlyWhenNothingElseDoesAndFlagsIt() {
        val lane = PillLane()
        lane.enter("import", PillLevel.AMBIENT)
        assertEquals(setOf("import"), lane.visible.value)
        assertFalse(lane.hidesAmbient.value)

        lane.enter("f", PillLevel.FEEDBACK)
        assertEquals(setOf("f"), lane.visible.value)
        assertTrue(lane.hidesAmbient.value)

        lane.leave("f")
        assertEquals(setOf("import"), lane.visible.value)
        assertFalse(lane.hidesAmbient.value)
    }

    @Test fun onlyTheNewestAmbientShows() {
        val lane = PillLane()
        lane.enter("a1", PillLevel.AMBIENT)
        lane.enter("a2", PillLevel.AMBIENT)
        assertEquals(setOf("a2"), lane.visible.value)
    }

    @Test fun leavingAnUnknownIdChangesNothing() {
        val lane = PillLane()
        lane.enter("r", PillLevel.RESULT)
        lane.leave("nope")
        assertEquals(setOf("r"), lane.visible.value)
    }
}
