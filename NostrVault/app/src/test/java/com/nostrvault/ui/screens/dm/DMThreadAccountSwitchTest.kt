package com.nostrvault.ui.screens.dm

import androidx.lifecycle.SavedStateHandle
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.service.BlossomService
import com.nostrvault.service.DMService
import com.nostrvault.service.NostrService
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** Switching account with a chat open closes it and drops its draft (Messages check A5). */
@OptIn(ExperimentalCoroutinesApi::class)
class DMThreadAccountSwitchTest {
    private val alice = "a".repeat(64)
    private val bob = "b".repeat(64)
    private val them = "c".repeat(64)
    private val active = MutableStateFlow(alice)
    private val dmService = mockk<DMService>(relaxed = true)
    private lateinit var vm: DMThreadViewModel

    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        every { dmService.messagesForConversation(any()) } returns MutableStateFlow(emptyList())
        every { dmService.pendingDecryptCount } returns MutableStateFlow(0)
        every { dmService.dmUnavailable } returns MutableStateFlow(null)
        val nostrService = mockk<NostrService>(relaxed = true)
        every { nostrService.profiles } returns MutableStateFlow(emptyMap())
        val configStore = mockk<ConfigStore>(relaxed = true)
        every { configStore.activeAccountHexPubkey } returns active
        vm = DMThreadViewModel(
            savedStateHandle = SavedStateHandle(mapOf("pubkey" to them)),
            context = mockk(relaxed = true),
            dmService = dmService,
            nostrService = nostrService,
            configStore = configStore,
            blossomService = mockk<BlossomService>(relaxed = true),
        )
    }

    @After
    fun tearDown() = Dispatchers.resetMain()

    @Test
    fun `a switch closes the chat and drops what was typed`() {
        vm.setMessageText("for alice's friend only")
        active.value = bob
        assertTrue(vm.closedBySwitch.value)
        assertEquals("", vm.messageField.text.toString())
    }

    @Test
    fun `nothing typed before the switch goes out as the new account`() {
        vm.setMessageText("for alice's friend only")
        active.value = bob
        vm.sendMessage()
        coVerify(exactly = 0) { dmService.sendMessage(any(), any(), any()) }
    }

    @Test
    fun `the same account again is not a switch`() {
        vm.setMessageText("draft")
        active.value = alice
        assertFalse(vm.closedBySwitch.value)
        assertEquals("draft", vm.messageField.text.toString())
    }

    @Test
    fun `the first account loading is not a switch`() {
        active.value = ""
        val fresh = DMThreadViewModel(
            savedStateHandle = SavedStateHandle(mapOf("pubkey" to them)),
            context = mockk(relaxed = true),
            dmService = dmService,
            nostrService = mockk<NostrService>(relaxed = true).also {
                every { it.profiles } returns MutableStateFlow(emptyMap())
            },
            configStore = mockk<ConfigStore>(relaxed = true).also {
                every { it.activeAccountHexPubkey } returns active
            },
            blossomService = mockk(relaxed = true),
        )
        fresh.setMessageText("draft")
        active.value = alice
        assertFalse(fresh.closedBySwitch.value)
        assertEquals("draft", fresh.messageField.text.toString())
    }
}
