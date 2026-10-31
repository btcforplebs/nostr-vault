package com.nostrvault.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Test

/** Type, pick a photo, type, leave: the draft goes to the relay once. */
class DraftSyncGateTest {

    /** The ON_STOPs that would sign, for a run of composer events. */
    private fun syncs(vararg events: String): Int {
        val gate = DraftSyncGate()
        var n = 0
        for (e in events) when (e) {
            "picker" -> gate.pickerOpening()
            "start" -> gate.started()
            "stop" -> if (gate.syncOnStop()) n++
        }
        return n
    }

    @Test fun pickingAPhotoIsNotLeaving() =
        assertEquals(0, syncs("start", "picker", "stop", "start"))

    @Test fun goingToTheBackgroundSyncs() =
        assertEquals(1, syncs("start", "stop"))

    @Test fun backFromThePickerThenBackgroundedSyncs() =
        assertEquals(1, syncs("start", "picker", "stop", "start", "stop"))

    @Test fun twoPhotosThenBackgroundedSyncsOnce() =
        assertEquals(1, syncs("start", "picker", "stop", "start", "picker", "stop", "start", "stop"))
}
