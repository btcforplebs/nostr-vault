package com.nostrvault.service

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.local.CredentialStore
import com.nostrvault.relay.HavenConfig
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkObject
import io.mockk.unmockkObject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancel
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.Collections

/**
 * A DM shows "Sending…" until one of their relays takes it, "Not sent" with
 * Try again and Remove when none does, and your own copy only goes out after
 * theirs was taken (Messages check A2).
 */
@OptIn(ExperimentalCoroutinesApi::class)
class DMDeliveryTest {
    private val them = "a".repeat(64)
    private val me = "b".repeat(64)
    private val theirRelays = listOf("wss://their.one", "wss://their.two")
    private val myRelay = "wss://mine"
    private val recipientWrap = """{"id":"${"1".repeat(64)}","kind":1059}"""
    private val selfWrap = """{"id":"${"2".repeat(64)}","kind":1059}"""
    private val id = "optimistic-1"

    private val dispatcher = StandardTestDispatcher()
    private lateinit var service: DMService

    /** Every publish, in order: (event, relay). */
    private val published = Collections.synchronizedList(mutableListOf<Pair<String, String>>())
    /** What each relay answers; a delay before answering, in ms. */
    private var answer: (String) -> String = { "rejected: blocked" }
    private var answerDelay: (String) -> Long = { 0 }

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
        mockkObject(CredentialStore)
        every { CredentialStore.getKeychainPassword(any()) } returns null
        every { CredentialStore.getNsec(any()) } returns null
        every { CredentialStore.getCredentialHexKey(any()) } returns null
        val configStore = mockk<ConfigStore>(relaxed = true)
        every { configStore.config } returns MutableStateFlow(HavenConfig(ownerNpub = "npub1owner", dmRelays = listOf(myRelay)))
        every { configStore.accountSwitches } returns emptyFlow()
        service = DMService(
            configStore = configStore,
            credentialStore = CredentialStore,
            nostrService = mockk(relaxed = true),
            amberSignerService = mockk(relaxed = true),
            feedService = stubFeedService(),
        )
        service.publishDM = { event, relay, _ ->
            delay(answerDelay(relay))
            published += event to relay
            answer(relay)
        }
        service.addMessageToConversation(
            them,
            DMMessage(id, "hello", 1_700_000_000, me, isFromMe = true, sendState = DMSendState.SENDING, resendText = "hello"),
        )
    }

    @After
    fun tearDown() {
        // Nothing of this service may resume on Main after resetMain (it would fail a later test).
        service.scope.cancel()
        unmockkObject(CredentialStore)
        Dispatchers.resetMain()
    }

    private fun mine() = service._conversations.value.first { it.id == them }.messages.first { it.id == id }
    private suspend fun deliver() =
        service.deliverNIP17(null, them, id, recipientWrap, selfWrap, theirRelays, me)

    @Test
    fun `refused by every relay it says Not sent, and your copy never goes out`() = runTest(dispatcher) {
        deliver()
        advanceUntilIdle()
        assertEquals(DMSendState.FAILED, mine().sendState)
        assertEquals("None of their 2 relays took it.", mine().failure)
        assertTrue(service.canRetry(mine()))
        assertFalse("self-copy published after a refusal", published.any { it.first == selfWrap })
    }

    @Test
    fun `timed out everywhere it says Not sent`() = runTest(dispatcher) {
        answer = { "timed out" }
        deliver()
        advanceUntilIdle()
        assertEquals(DMSendState.FAILED, mine().sendState)
    }

    @Test
    fun `one relay taking it is enough, and only then your own copy goes`() = runTest(dispatcher) {
        answer = { if (it == theirRelays[1]) "accepted" else "rejected: blocked" }
        answerDelay = { if (it == theirRelays[1]) 500 else 0 }
        deliver()
        advanceUntilIdle()
        assertNull(mine().sendState)
        assertNull(mine().failure)
        val firstSelf = published.indexOfFirst { it.first == selfWrap }
        val taken = published.indexOf(recipientWrap to theirRelays[1])
        assertTrue("self-copy not published", firstSelf >= 0)
        assertEquals(myRelay, published[firstSelf].second)
        assertTrue("self-copy went out before theirs was taken", firstSelf > taken)
    }

    @Test
    fun `it stays Sending until a relay answers`() = runTest(dispatcher) {
        answer = { "accepted" }
        answerDelay = { 2_000 }
        launch { deliver() }
        advanceTimeBy(1_000)
        runCurrent()
        assertEquals(DMSendState.SENDING, mine().sendState)
        advanceUntilIdle()
        assertNull(mine().sendState)
    }

    @Test
    fun `Try again sends the same signed copy again`() = runTest(dispatcher) {
        deliver()
        advanceUntilIdle()
        val before = published.filter { it.first == recipientWrap }.size
        answer = { "accepted" }
        service.retrySend(them, id)
        advanceUntilIdle()
        assertNull(mine().sendState)
        assertTrue(published.filter { it.first == recipientWrap }.size > before)
        assertTrue(published.any { it.first == selfWrap })
    }

    @Test
    fun `Remove takes the bubble and its Try again away`() = runTest(dispatcher) {
        deliver()
        advanceUntilIdle()
        service.removeUnsent(them, id)
        assertTrue(service._conversations.value.none { c -> c.messages.any { it.id == id } })
        assertFalse(service.sendRetries.containsKey(id))
    }

    @Test
    fun `a send cut off by a restart loads as Not sent`() {
        val saved = listOf(
            DMConversation(
                them,
                listOf(
                    DMMessage("x", "sent long ago", 1, me, isFromMe = true),
                    DMMessage("y", "was sending", 2, me, isFromMe = true, sendState = DMSendState.SENDING, resendText = "was sending"),
                ),
            ),
        )
        val loaded = saved.withInterruptedSendsFailed().first().messages
        assertNull(loaded[0].sendState)
        assertEquals(DMSendState.FAILED, loaded[1].sendState)
        assertEquals(INTERRUPTED_SEND, loaded[1].failure)
        // Its words survive to be sent again; Try again is offered.
        assertTrue(service.canRetry(loaded[1]))
    }

    @Test
    fun `a locked photo after a restart can only be removed`() {
        val photo = DMMessage("p", "https://x/y#key", 3, me, isFromMe = true, sendState = DMSendState.FAILED, failure = "f")
        assertFalse(service.canRetry(photo))
    }

    // Tron #2230 must-fixes.

    @Test
    fun `a second Try again while the first is going sends nothing more`() = runTest(dispatcher) {
        deliver()
        advanceUntilIdle()
        val before = published.size
        answer = { "accepted" }
        answerDelay = { 1_000 }
        service.retrySend(them, id)
        runCurrent()
        service.retrySend(them, id) // double tap
        advanceUntilIdle()
        // One more round to their two relays, plus your copy: no second message.
        assertEquals(2, published.drop(before).count { it.first == recipientWrap })
        val mineNow = service._conversations.value.first { it.id == them }.messages
        assertEquals(listOf(id), mineNow.map { it.id })
        assertNull(mineNow.single().sendState)
    }

    @Test
    fun `Try again after a restart keeps the words when the message can't be built`() = runTest(dispatcher) {
        // No key on this device: sendDM throws before anything is published.
        service.setSendState(null, them, id, DMSendState.FAILED, INTERRUPTED_SEND)
        advanceUntilIdle()
        service.retrySend(them, id)
        // The build runs on the real IO dispatcher: wait for it, a bounded while.
        var waited = 0
        advanceUntilIdle()
        while (mine().sendState == DMSendState.SENDING && waited++ < 300) {
            Thread.sleep(10)
            advanceUntilIdle()
        }
        advanceUntilIdle()
        val kept = service._conversations.value.first { it.id == them }.messages.single { it.id == id }
        assertEquals(DMSendState.FAILED, kept.sendState)
        assertEquals("hello", kept.resendText)
    }

    @Test
    fun `a Not sent bubble never swallows a new message with the same words`() = runTest(dispatcher) {
        service.setSendState(null, them, id, DMSendState.FAILED, "x")
        advanceUntilIdle()
        service.addMessageToConversation(
            them, DMMessage("new", "hello", 1_700_000_001, me, isFromMe = true, sendState = DMSendState.SENDING),
        )
        assertEquals(listOf(id, "new"), service._conversations.value.first { it.id == them }.messages.map { it.id })
    }

    @Test
    fun `a publish cut off by a cancel still counts, so it never stays Sending`() = runTest(dispatcher) {
        service.publishDM = { _, _, _ -> throw kotlinx.coroutines.CancellationException("gone") }
        deliver()
        advanceUntilIdle()
        assertEquals(DMSendState.FAILED, mine().sendState)
    }
}
