package com.nostrvault.ui.screens.dm

import androidx.lifecycle.SavedStateHandle
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** A composer opened from a profile keeps its recipient: no X, and clearing does nothing. */
@OptIn(ExperimentalCoroutinesApi::class)
class NewMessageLockedRecipientTest {
    private val peer = "b".repeat(64)

    @Before fun setUp() { Dispatchers.setMain(StandardTestDispatcher()) }
    @After fun tearDown() { Dispatchers.resetMain() }

    private fun model(pubkey: String?) = NewMessageViewModel(
        savedStateHandle = SavedStateHandle(if (pubkey != null) mapOf("pubkey" to pubkey) else emptyMap()),
        context = mockk(relaxed = true),
        dmService = mockk(relaxed = true),
        nostrService = mockk(relaxed = true) { every { profiles } returns MutableStateFlow(emptyMap()) },
        blossomService = mockk(relaxed = true),
    )

    @Test fun `opened from a profile the recipient is locked and stays`() {
        val vm = model(peer)
        assertTrue(vm.recipientLocked)
        vm.clearRecipient()
        assertEquals(peer, vm.selectedRecipient.value)
    }

    @Test fun `opened from the inbox the picked recipient can be cleared`() {
        val vm = model(null)
        assertFalse(vm.recipientLocked)
        vm.selectRecipient(peer)
        vm.clearRecipient()
        assertNull(vm.selectedRecipient.value)
    }
}
