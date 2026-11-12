package com.nostrvault.ui.screens.feed

import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

class WiderWebFinishedTest {

    @Test
    fun aBuildTheRelayStartedThatEndsReloadsOnce() {
        var n = 0
        runTest { n = widerWebFinished(flowOf(false, true, true, false)).toList().size }
        assertEquals(1, n)
    }

    @Test
    fun neverBuildingOrStillBuildingDoesNotReload() {
        var a = -1
        var b = -1
        runTest {
            a = widerWebFinished(flowOf(false, false)).toList().size
            b = widerWebFinished(flowOf(false, true)).toList().size
        }
        assertEquals(0, a)
        assertEquals(0, b)
    }

    @Test
    fun twoBuildsReloadTwice() {
        var n = 0
        runTest { n = widerWebFinished(flowOf(true, false, true, false)).toList().size }
        assertEquals(2, n)
    }
}
