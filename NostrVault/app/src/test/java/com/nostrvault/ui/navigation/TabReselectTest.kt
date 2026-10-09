package com.nostrvault.ui.navigation

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

/** Vault / WOT tab reselect reaches only that tab's screen (iOS #275). */
@OptIn(ExperimentalCoroutinesApi::class)
class TabReselectTest {
    @Test
    fun eachTabHearsOnlyItsOwnReselect() = runTest {
        val relay = mutableListOf<Screen>()
        val wot = mutableListOf<Screen>()
        val dispatcher = UnconfinedTestDispatcher(testScheduler)
        val a = launch(dispatcher) { TabReselect.of(Screen.Dashboard).toList(relay) }
        val b = launch(dispatcher) { TabReselect.of(Screen.WOT).toList(wot) }

        TabReselect.request(Screen.Dashboard)
        TabReselect.request(Screen.WOT)
        TabReselect.request(Screen.Dashboard)

        assertEquals(listOf(Screen.Dashboard, Screen.Dashboard), relay)
        assertEquals(listOf(Screen.WOT), wot)
        a.cancel(); b.cancel()
    }
}
