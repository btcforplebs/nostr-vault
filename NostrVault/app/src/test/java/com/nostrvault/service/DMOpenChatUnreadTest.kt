package com.nostrvault.service

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.local.CredentialStore
import com.nostrvault.relay.HavenConfig
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkObject
import io.mockk.unmockkObject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test

/** Messages that arrive in the chat on screen are read as they arrive (Messages check A4). */
@OptIn(ExperimentalCoroutinesApi::class)
class DMOpenChatUnreadTest {
    private val owner = "npub1owner"
    private val alice = "a".repeat(64)
    private val bob = "b".repeat(64)
    private lateinit var service: DMService

    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        mockkObject(CredentialStore)
        every { CredentialStore.getKeychainPassword(any()) } returns null
        every { CredentialStore.getNsec(any()) } returns null
        every { CredentialStore.getCredentialHexKey(any()) } returns null
        val configStore = mockk<ConfigStore>(relaxed = true)
        every { configStore.config } returns MutableStateFlow(HavenConfig(ownerNpub = owner))
        every { configStore.accountSwitches } returns emptyFlow()
        service = DMService(
            configStore = configStore,
            credentialStore = CredentialStore,
            nostrService = mockk(relaxed = true),
            amberSignerService = mockk(relaxed = true),
            feedService = stubFeedService(),
        )
    }

    @After
    fun tearDown() {
        unmockkObject(CredentialStore)
        Dispatchers.resetMain()
    }

    private var n = 0
    private fun from(sender: String) = DMMessage(
        id = "%064d".format(++n),
        content = "hi $n",
        timestamp = 1_700_000_000L + n,
        senderPubkey = sender,
        isFromMe = false,
    )

    private fun unread(counterparty: String) =
        service._conversations.value.first { it.id == counterparty }.unreadCount

    @Test
    fun `a message in the chat on screen is not unread`() {
        service.addMessageToConversation(alice, from(alice)) // chat exists, closed
        assertEquals(1, unread(alice))
        service.markRead(alice)
        service.visibleConversation = alice
        service.addMessageToConversation(alice, from(alice))
        service.addMessageToConversation(alice, from(alice))
        assertEquals(0, unread(alice))
    }

    @Test
    fun `a first message from someone whose chat is on screen is not unread`() {
        service.visibleConversation = alice
        service.addMessageToConversation(alice, from(alice))
        assertEquals(0, unread(alice))
    }

    @Test
    fun `another chat still counts while one is open`() {
        service.visibleConversation = alice
        service.addMessageToConversation(bob, from(bob))
        service.addMessageToConversation(bob, from(bob))
        assertEquals(2, unread(bob))
    }

    @Test
    fun `once the chat is closed, new messages count again`() {
        service.visibleConversation = alice
        service.addMessageToConversation(alice, from(alice))
        service.visibleConversation = null
        service.addMessageToConversation(alice, from(alice))
        assertEquals(1, unread(alice))
    }
}
