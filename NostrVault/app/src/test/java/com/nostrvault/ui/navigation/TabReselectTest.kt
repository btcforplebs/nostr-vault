package com.nostrvault.ui.navigation

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

/** Relay / Media tab reselect reaches only that tab's screen (iOS #275). */
@OptIn(ExperimentalCoroutinesApi::class)
class TabReselectTest {
    @Test
    fun eachTabHearsOnlyItsOwnReselect() = runTest {
        val relay = mutableListOf<Screen>()
        val media = mutableListOf<Screen>()
        val dispatcher = UnconfinedTestDispatcher(testScheduler)
        val a = launch(dispatcher) { TabReselect.of(Screen.Dashboard).toList(relay) }
        val b = launch(dispatcher) { TabReselect.of(Screen.MediaGallery).toList(media) }

        TabReselect.request(Screen.Dashboard)
        TabReselect.request(Screen.MediaGallery)
        TabReselect.request(Screen.Dashboard)

        assertEquals(listOf(Screen.Dashboard, Screen.Dashboard), relay)
        assertEquals(listOf(Screen.MediaGallery), media)
        a.cancel(); b.cancel()
    }
}
