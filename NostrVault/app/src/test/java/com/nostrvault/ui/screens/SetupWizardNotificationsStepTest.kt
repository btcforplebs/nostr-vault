package com.nostrvault.ui.screens

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenConfig
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** Setup's "Stay in the Loop" step (iOS PushNotificationStep). */
@OptIn(ExperimentalCoroutinesApi::class)
class SetupWizardNotificationsStepTest {

    private var saved = HavenConfig()
    private lateinit var viewModel: SetupWizardViewModel

    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val configStore = mockk<ConfigStore>(relaxed = true)
        every { configStore.update(any()) } answers {
            saved = firstArg<(HavenConfig) -> HavenConfig>()(saved)
        }
        every { configStore.config } answers { kotlinx.coroutines.flow.MutableStateFlow(saved) }
        viewModel = SetupWizardViewModel(
            configStore = configStore,
            credentialStore = mockk(relaxed = true),
            amberSignerService = mockk(relaxed = true),
            blossomService = mockk(relaxed = true),
            nostrService = mockk(relaxed = true),
            relayImportService = mockk(relaxed = true),
            statsService = mockk(relaxed = true),
            appContext = mockk(relaxed = true),
        )
    }

    @After
    fun tearDown() = Dispatchers.resetMain()

    @Test
    fun `full setup asks about notifications between the wallet and done`() {
        viewModel.setSetupPath(SetupPath.FULL)
        val steps = viewModel.activeSteps
        assertEquals(steps.indexOf(WizardStep.WALLET) + 1, steps.indexOf(WizardStep.NOTIFICATIONS))
        assertEquals(WizardStep.COMPLETE, steps.last())
    }

    @Test
    fun `leaving the wallet goes to the notifications step`() {
        viewModel.setSetupPath(SetupPath.FULL)
        viewModel.skipWallet()
        assertEquals(WizardStep.NOTIFICATIONS, viewModel.step.value)
    }

    @Test
    fun `enable saves the toggles and moves on`() {
        viewModel.setSetupPath(SetupPath.FULL)
        viewModel.finishNotifications(enable = true, dms = true, zaps = false, mentions = true)
        assertTrue(saved.notificationPermissionAsked)
        assertTrue(saved.pushNotifyDMs)
        assertFalse(saved.pushNotifyZaps)
        assertTrue(saved.pushNotifyMentions)
        assertEquals(WizardStep.COMPLETE, viewModel.step.value)
    }

    @Test
    fun `not now keeps the defaults but is not asked again`() {
        viewModel.setSetupPath(SetupPath.FULL)
        viewModel.finishNotifications(enable = false, dms = false, zaps = false, mentions = false)
        assertTrue(saved.notificationPermissionAsked)
        assertTrue(saved.pushNotifyDMs)
        assertTrue(saved.pushNotifyZaps)
        assertTrue(saved.pushNotifyMentions)
        assertEquals(WizardStep.COMPLETE, viewModel.step.value)
    }
}
