package com.nostrvault.service

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.relay.HavenConfig
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.just
import io.mockk.mockkObject
import io.mockk.mockkStatic
import io.mockk.runs
import io.mockk.unmockkStatic
import io.mockk.unmockkObject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * A zap must never pay an invoice for a different amount than the user chose
 * (audit K1). The LNURL provider is the party being checked, so its invoice is
 * the input here; the wallet must not be asked to pay a swapped one.
 */
class ZapSendServiceInvoiceAmountTest {
    private val author = "a".repeat(64)
    private val nostr = mockk<NostrService>(relaxed = true)
    private val nwc = mockk<NWCService>(relaxed = true)
    private val config = mockk<ConfigStore>()
    private val feed = mockk<FeedService>(relaxed = true)
    private val service = ZapSendService(nostr, nwc, config, feed)

    @Before fun setUp() {
        every { config.config } returns MutableStateFlow(HavenConfig(nwcURI = "nostr+walletconnect://x"))
        every { nostr.profiles } returns MutableStateFlow(mapOf(author to FeedProfile(pubkey = author, lud16 = "bob@example.com")))
        mockkObject(LNURLService)
        coEvery { LNURLService.resolveAddress(any()) } returns LNURLPayResponse(
            callback = "https://example.com/cb", maxSendable = 100_000_000_000, minSendable = 1_000,
            metadata = "[]", tag = "payRequest",
        )
        coEvery { nwc.payInvoice(any()) } returns "preimage"
        // The optimistic total bump after paying is an extension on FeedService.
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

    private fun invoiceIs(bolt11: String) {
        coEvery { LNURLService.fetchInvoice(any(), any(), any(), any()) } returns bolt11
    }

    @Test fun anInvoiceForMoreThanTheZapIsNeverPaid() = runBlocking {
        invoiceIs("lnbc10m1pjunk") // 1,000,000 sats for a 21-sat zap
        val result = service.zapNote("e".repeat(64), author, 21)
        assertTrue(result.exceptionOrNull() is ZapSendService.ZapError.WrongInvoiceAmount)
        coVerify(exactly = 0) { nwc.payInvoice(any()) }
    }

    @Test fun anAmountlessInvoiceIsNeverPaid() = runBlocking {
        // The wallet would pick the amount, which is what a hostile provider wants.
        invoiceIs("lnbc1pjunk")
        assertTrue(service.zapNote("e".repeat(64), author, 21).exceptionOrNull() is ZapSendService.ZapError.WrongInvoiceAmount)
        coVerify(exactly = 0) { nwc.payInvoice(any()) }
    }

    @Test fun aFewExtraMsatIsStillWrong() = runBlocking {
        invoiceIs("lnbc210010p1pjunk") // 21,001 msat for 21,000
        assertTrue(service.zapNote("e".repeat(64), author, 21).exceptionOrNull() is ZapSendService.ZapError.WrongInvoiceAmount)
        coVerify(exactly = 0) { nwc.payInvoice(any()) }
    }

    @Test fun theExactAmountIsPaid() = runBlocking {
        invoiceIs("lnbc210n1pjunk") // 21 sats
        assertTrue(service.zapNote("e".repeat(64), author, 21).isSuccess)
        coVerify(exactly = 1) { nwc.payInvoice("lnbc210n1pjunk") }
    }
}
