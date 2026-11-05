package com.nostrvault.ui.screens

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenConfig
import com.nostrvault.service.StatsService
import com.nostrvault.setup.NotificationAsk
import com.nostrvault.setup.ReadyCounts
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Before
import org.junit.Test

/** First run's pop-ups and the import tour's Ready card (PLANS/NV_FIRST_RUN_ENTRY_PLAN_2026_11_05.md §4). */
@OptIn(ExperimentalCoroutinesApi::class)
class SetupWizardFirstRunPopupsTest {

    private var saved = HavenConfig()
    private val loaded = MutableStateFlow(0)
    private val kinds = MutableStateFlow<Map<Int, Int>>(emptyMap())
    private lateinit var viewModel: SetupWizardViewModel

    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val configStore = mockk<ConfigStore>(relaxed = true)
        every { configStore.update(any()) } answers {
            saved = firstArg<(HavenConfig) -> HavenConfig>()(saved)
        }
        every { configStore.config } answers { MutableStateFlow(saved) }
        val stats = mockk<StatsService>(relaxed = true)
        every { stats.loadedEventsCount } returns loaded
        every { stats.kindCounts } returns kinds
        coEvery { stats.fetchCountsByKind(any(), any(), any()) } returns StatsService.CountResult.COMPLETE
        viewModel = SetupWizardViewModel(
            configStore = configStore,
            credentialStore = mockk(relaxed = true),
            amberSignerService = mockk(relaxed = true),
            blossomService = mockk(relaxed = true),
            nostrService = mockk(relaxed = true),
            relayImportService = mockk(relaxed = true),
            statsService = stats,
            appContext = mockk(relaxed = true),
        )
    }

    @After
    fun tearDown() = Dispatchers.resetMain()

    @Test
    fun `finishing setup does not switch push on before the person answers`() {
        viewModel.choosePath(SetupPath.USE_NOSTR)
        viewModel.completeSetup {}
        assertFalse(saved.enablePushNotifications)
    }

    @Test
    fun `the Ready card stops counting within 3 s and never shows 0`() = runTest {
        viewModel.loadTourCounts()
        advanceTimeBy(3_001)
        assertNotNull("still counting after 3 s", viewModel.tourCounts.value)
        assertNotEquals(Triple(0, 0, 0), viewModel.tourCounts.value)
    }

    @Test
    fun `finishing setup leaves the notification question for the main screen`() {
        viewModel.choosePath(SetupPath.USE_NOSTR)
        viewModel.completeSetup {}
        assertTrue(saved.hasCompletedSetup)
        assertTrue(saved.notificationAskPending)
    }

    @Test
    fun `the Ready card shows real counts at once, without a 0 tile`() = runTest {
        loaded.value = 12
        kinds.value = mapOf(1 to 4, 7 to 0)
        viewModel.loadTourCounts()
        assertEquals(listOf(4 to "notes", 12 to "in all"), viewModel.tourCounts.value?.tiles)
    }

    @Test
    fun `nothing counted yet is an honest line, not zeros`() = runTest {
        viewModel.loadTourCounts()
        advanceTimeBy(3_001)
        assertEquals(emptyList<Pair<Int, String>>(), viewModel.tourCounts.value?.tiles)
    }

    @Test
    fun `ReadyCounts keeps only real counts`() {
        assertEquals(listOf(5 to "notes", 7 to "in all"), ReadyCounts.from(5, 0, 7).tiles)
        assertEquals(emptyList<Pair<Int, String>>(), ReadyCounts.from(0, 0, 0).tiles)
        assertEquals(3, ReadyCounts.from(1, 2, 3).tiles.size)
    }

    @Test
    fun `the notification question is asked once, only right after setup`() {
        val pending = HavenConfig(hasCompletedSetup = true, notificationAskPending = true)
        assertEquals(NotificationAsk.Action.ASK, NotificationAsk.next(pending, needsPermission = true, granted = false))
        assertEquals(NotificationAsk.Action.ALLOWED, NotificationAsk.next(pending, needsPermission = false, granted = true))
        assertEquals(NotificationAsk.Action.ALLOWED, NotificationAsk.next(pending, needsPermission = true, granted = true))
        // A later launch, or an upgraded install never asked: no cold question.
        assertEquals(NotificationAsk.Action.NONE, NotificationAsk.next(pending.copy(notificationAskPending = false), true, false))
        assertEquals(NotificationAsk.Action.NONE, NotificationAsk.next(HavenConfig(notificationAskPending = true), true, false))
    }

    @Test
    fun `push is on only after a yes, and the question is never asked again`() {
        val pending = HavenConfig(hasCompletedSetup = true, notificationAskPending = true)
        val yes = NotificationAsk.answered(pending, granted = true)
        assertTrue(yes.enablePushNotifications)
        assertFalse(yes.notificationAskPending)
        assertTrue(yes.notificationPermissionAsked)
        val no = NotificationAsk.answered(pending, granted = false)
        assertFalse(no.enablePushNotifications)
        assertEquals(NotificationAsk.Action.NONE, NotificationAsk.next(no, needsPermission = true, granted = false))
    }
}
