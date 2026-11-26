package com.nostrvault.service

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.relay.HavenConfig
import com.nostrvault.ui.notification.NotificationManager
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.just
import io.mockk.mockk
import io.mockk.mockkObject
import io.mockk.mockkStatic
import io.mockk.runs
import io.mockk.unmockkObject
import io.mockk.unmockkStatic
import io.mockk.verify
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * RESEARCH/NV_MINIBITS_ZAP_REVIEW_2026_11_19.md fixes 1-3 (Logen 4f097fe0):
 * an unconfirmed zap is not a failed one, its receipt confirms it, and a
 * second zap on a pending note asks first.
 */
class ZapConfirmTest {
    private val invoice = "lnbc210n1pjunk"

    private fun receipt(bolt11: String, kind: Int = 9735): JsonObject = Json.parseToJsonElement(
        """{"kind":$kind,"pubkey":"${"b".repeat(64)}","tags":[["p","${"a".repeat(64)}"],["bolt11","$bolt11"],["description","{}"]]}""",
    ).jsonObject

    // ── Pure rules ──

    @Test fun `only a receipt for the exact invoice counts`() {
        assertTrue(ZapConfirm.receiptPaysInvoice(receipt(invoice), invoice))
        assertTrue("bech32 is case-insensitive", ZapConfirm.receiptPaysInvoice(receipt(invoice.uppercase()), invoice))
        assertFalse(ZapConfirm.receiptPaysInvoice(receipt("lnbc210n1pother"), invoice))
        assertFalse("not a receipt", ZapConfirm.receiptPaysInvoice(receipt(invoice, kind = 1), invoice))
    }

    @Test fun `the receipt filter asks for this note's receipts since just before the request`() {
        val f = Json.parseToJsonElement(ZapConfirm.receiptFilter("a".repeat(64), "e".repeat(64), 1_000)).jsonObject
        assertEquals("[9735]", f["kinds"].toString())
        assertEquals("[\"${"e".repeat(64)}\"]", f["#e"].toString())
        assertEquals("940", f["since"].toString())
        val profileZap = Json.parseToJsonElement(ZapConfirm.receiptFilter("a".repeat(64), "", 1_000)).jsonObject
        assertFalse(profileZap.containsKey("#e"))
    }

    @Test fun `the wallet gets 90 s, the same as the iPhone`() {
        assertEquals(90_000L, ZapConfirm.WALLET_WAIT_MS)
    }

    @Test fun `a pending note asks once, and a second tap soon after goes through`() {
        var now = 0L
        val pending = PendingZaps { now }
        assertTrue(pending.mayZap("n"))
        pending.begin("n")
        now = 5_000
        assertFalse("asks first", pending.mayZap("n"))
        now = 10_000
        assertTrue("the second tap sends another", pending.mayZap("n"))
        pending.begin("n")
        now = 20_000
        assertFalse(pending.mayZap("n"))
        now = 20_000 + PendingZaps.CONFIRM_MS + 1
        assertFalse("too late a tap asks again", pending.mayZap("n"))
    }

    @Test fun `a pending zap stops counting once it ends or runs out`() {
        var now = 0L
        val pending = PendingZaps { now }
        pending.begin("n")
        pending.end("n")
        assertTrue(pending.mayZap("n"))
        pending.begin("m")
        pending.answered("m")
        now = PendingZaps.PENDING_MS + 1
        assertTrue(pending.mayZap("m"))
        assertTrue("other notes are not held", pending.mayZap("other"))
    }

    @Test fun `a zap whose wallet hasn't answered stays pending past the window`() {
        var now = 0L
        val pending = PendingZaps { now }
        pending.begin("n")
        now = PendingZaps.PENDING_MS + 60_000
        assertTrue("still paying", pending.isPending("n"))
        assertFalse("a tap is asked first", pending.mayZap("n"))
        pending.answered("n")
        now += PendingZaps.PENDING_MS
        assertTrue("the window runs from the answer", pending.isPending("n"))
        now += 1
        assertFalse(pending.isPending("n"))
        assertTrue(pending.mayZap("n"))
    }

    // ── The zap flow ──

    private val author = "a".repeat(64)
    private val noteId = "e".repeat(64)
    private val nostr = mockk<NostrService>(relaxed = true)
    private val nwc = mockk<NWCService>(relaxed = true)
    private val config = mockk<ConfigStore>()
    private val feed = mockk<FeedService>(relaxed = true)
    private val notifications = mockk<NotificationManager>(relaxed = true)
    private val service = ZapSendService(nostr, nwc, config, feed, notifications)

    @Before fun setUp() {
        every { config.config } returns MutableStateFlow(
            HavenConfig(nwcURI = "nostr+walletconnect://x", feedRelays = listOf("wss://relay.example")),
        )
        every { nostr.profiles } returns MutableStateFlow(mapOf(author to FeedProfile(pubkey = author, lud16 = "bob@example.com")))
        every { nostr.relayLists } returns MutableStateFlow(mapOf(author to listOf("wss://inbox.example")))
        mockkObject(LNURLService)
        coEvery { LNURLService.resolveAddress(any()) } returns LNURLPayResponse(
            callback = "https://example.com/cb", maxSendable = 100_000_000_000, minSendable = 1_000,
            metadata = "[]", tag = "payRequest", allowsNostr = true,
        )
        coEvery { LNURLService.fetchInvoice(any(), any(), any(), any()) } returns invoice
        mockkStatic(FEED_ACTIONS)
        every { feed.zapNote(any(), any()) } just runs
    }

    @After fun tearDown() {
        unmockkObject(LNURLService)
        unmockkStatic(FEED_ACTIONS)
    }

    private companion object {
        const val FEED_ACTIONS = "com.nostrvault.service.FeedServiceEngagementActionsKt"
    }

    @Test fun `the receipt arriving before the wallet answers is a paid zap`() = runBlocking {
        coEvery { nwc.payInvoice(any()) } coAnswers { delay(60_000); "late" }
        coEvery { nostr.queryRawEvents(any(), any(), any(), any(), any()) } returns listOf(receipt(invoice))
        val result = service.zapNote(noteId, author, 21)
        assertTrue(result.isSuccess)
        verify(exactly = 1) { feed.zapNote(noteId, 21) }
    }

    @Test fun `a wallet that never answers is may-still-arrive, not failed, and a late receipt lights the bolt`() = runBlocking {
        coEvery { nwc.payInvoice(any()) } throws NWCTimeoutException()
        var asks = 0
        coEvery { nostr.queryRawEvents(any(), any(), any(), any(), any()) } coAnswers {
            asks++
            if (asks > 1) listOf(receipt(invoice)) else emptyList()
        }
        val result = service.zapNote(noteId, author, 21)
        assertTrue(result.exceptionOrNull() is ZapSendService.ZapError.MayStillArrive)
        verify(timeout = 15_000, exactly = 1) { feed.zapNote(noteId, 21) }
        verify(timeout = 5_000) { notifications.zapConfirmedLater(any(), 21) }
    }

    @Test fun `no preimage and no receipt stays may-still-arrive and lights nothing`() = runBlocking {
        coEvery { nwc.payInvoice(any()) } throws NWCNoPreimageException()
        coEvery { nostr.queryRawEvents(any(), any(), any(), any(), any()) } returns listOf(receipt("lnbc210n1pother"))
        val result = service.zapNote(noteId, author, 21)
        assertTrue(result.exceptionOrNull() is ZapSendService.ZapError.MayStillArrive)
        verify(exactly = 0) { feed.zapNote(any(), any()) }
    }

    @Test fun `zapping a note with one pending asks first, then a second tap pays again`() = runBlocking {
        coEvery { nwc.payInvoice(any()) } throws NWCTimeoutException()
        coEvery { nostr.queryRawEvents(any(), any(), any(), any(), any()) } returns emptyList()
        service.zapNote(noteId, author, 21)
        val asked = service.zapNote(noteId, author, 21)
        assertTrue(asked.exceptionOrNull() is ZapSendService.ZapError.StillPending)
        coVerify(exactly = 1) { nwc.payInvoice(any()) }
        service.zapNote(noteId, author, 21)
        coVerify(exactly = 2) { nwc.payInvoice(any()) }
    }

    @Test fun `a wallet error is still a failure, and the note is not held`() = runBlocking {
        coEvery { nwc.payInvoice(any()) } throws NWCNotSentException("No relay")
        coEvery { nostr.queryRawEvents(any(), any(), any(), any(), any()) } returns emptyList()
        val result = service.zapNote(noteId, author, 21)
        assertTrue(result.exceptionOrNull() is ZapSendService.ZapError.PaymentFailed)
        assertFalse(service.pendingZaps.isPending(noteId))
    }
}
