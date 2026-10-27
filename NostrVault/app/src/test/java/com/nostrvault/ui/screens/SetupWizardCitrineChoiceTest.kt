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

/** Citrine on the phone: the relay choice is "Use Nostr Vault" or "Use Citrine". */
@OptIn(ExperimentalCoroutinesApi::class)
class SetupWizardCitrineChoiceTest {

    private var saved = HavenConfig()
    private val packageManager = mockk<android.content.pm.PackageManager>()
    private val appContext = mockk<android.content.Context>(relaxed = true)

    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        every { appContext.packageManager } returns packageManager
    }

    @After
    fun tearDown() = Dispatchers.resetMain()

    private fun viewModel(citrine: Boolean): SetupWizardViewModel {
        if (citrine) {
            every { packageManager.getPackageInfo("com.greenart7c3.citrine", 0) } returns mockk()
        } else {
            every { packageManager.getPackageInfo(any<String>(), any<Int>()) } throws
                android.content.pm.PackageManager.NameNotFoundException()
        }
        val configStore = mockk<ConfigStore>(relaxed = true)
        every { configStore.update(any()) } answers {
            saved = firstArg<(HavenConfig) -> HavenConfig>()(saved)
        }
        every { configStore.config } answers { kotlinx.coroutines.flow.MutableStateFlow(saved) }
        return SetupWizardViewModel(
            configStore = configStore,
            credentialStore = mockk(relaxed = true),
            amberSignerService = mockk(relaxed = true),
            blossomService = mockk(relaxed = true),
            nostrService = mockk(relaxed = true),
            relayImportService = mockk(relaxed = true),
            statsService = mockk(relaxed = true),
            appContext = appContext,
        )
    }

    @Test
    fun `setup notices Citrine on the phone`() {
        assertTrue(viewModel(citrine = true).citrineInstalled.value)
    }

    @Test
    fun `no Citrine leaves the relay choice as it was`() {
        assertFalse(viewModel(citrine = false).citrineInstalled.value)
    }

    @Test
    fun `Use Citrine fills its address and takes the external relay path`() {
        val vm = viewModel(citrine = true)
        vm.choosePath(SetupPath.USE_NOSTR)
        vm.chooseCitrine(true)
        vm.advanceFromRelayChoice()

        assertTrue(saved.useExternalRelay)
        assertEquals("ws://127.0.0.1:4869", saved.externalRelayURL)
        assertEquals("", saved.externalBlossomURL)
        assertEquals(listOf(WizardStep.USE_NOSTR_KEY, WizardStep.COMPLETE), vm.activeSteps.drop(2))
        assertEquals(WizardStep.USE_NOSTR_KEY, vm.step.value)
    }

    @Test
    fun `Use Nostr Vault is the normal setup`() {
        val vm = viewModel(citrine = true)
        vm.choosePath(SetupPath.USE_NOSTR)
        vm.chooseCitrine(true)
        vm.chooseCitrine(false)
        vm.advanceFromRelayChoice()

        assertFalse(saved.useExternalRelay)
        assertEquals(
            listOf(WizardStep.USE_NOSTR_KEY, WizardStep.BACKUP_QUESTION, WizardStep.RELAY_CHECK, WizardStep.IMPORT_TOUR),
            vm.activeSteps.drop(2),
        )
    }

    @Test
    fun `Nostr Vault is picked until the person picks Citrine`() {
        val vm = viewModel(citrine = true)
        vm.choosePath(SetupPath.FULL)
        vm.advanceFromRelayChoice()
        assertFalse(saved.useExternalRelay)
        assertEquals(WizardStep.ACCOUNT, vm.step.value)
    }
}
