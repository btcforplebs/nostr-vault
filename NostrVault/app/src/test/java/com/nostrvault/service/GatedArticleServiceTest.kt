package com.nostrvault.service

import android.content.Context
import android.content.SharedPreferences
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.GatedArticle
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Zap-to-unlock is back for Fanfares articles only (owner, 2026-10-20). Any
 * gated article opens from a stored key; a non-Fanfares one is never signed
 * for, asked for or paid. A share that might have been paid is never offered
 * again (iOS GatedArticleService before #812).
 */
class GatedArticleServiceTest {
    private val author = "adc14fa3ad590856dd8b80815d367f7c1e6735ad00fd98a86d002fbe9fb535e1"
    private val other = "c".repeat(64)
    private val reader = "b".repeat(64)
    private val blob = "AQIDBAUGBwgJCgsMWVJSyIdkwGGGkd2kTIZsMgf2yoQI++wXRPfUyTlbSWgkrDfVohPZs+M3pLRXdVxSVrYS98ZTHe8/9vfNgHI8mpNeo5hR6fphTQME+3RawQ=="
    private val key = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
    private val coordinate = "30023:$author:d6711eb7-0703-48bb-9fd5-61b96e57283c"
    private val storedAt = "$reader|$coordinate"

    private fun tags(keyUrl: String, zaps: List<List<String>> = listOf(listOf("zap", author, "wss://fanfares.nostr1.com", "42"))) = listOf(
        listOf("d", "d6711eb7-0703-48bb-9fd5-61b96e57283c"),
        listOf("encrypted", "aes-256-gcm", blob, keyUrl),
        listOf("price", "42", "SATS"),
    ) + zaps

    private fun note(tags: List<List<String>>) =
        FeedNote(id = "n1", pubkey = author, content = "Teaser.", createdAt = java.util.Date(0), tags = tags, kind = 30023)

    private val fanfares = note(tags("https://api.fanfares.live/request-key"))
    private val fanfaresGated = GatedArticle.from(fanfares)!!
    private val split = note(tags("https://api.fanfares.live/request-key",
        listOf(listOf("zap", author, "wss://fanfares.nostr1.com", "1"), listOf("zap", other, "", "1"))))
    private val splitGated = GatedArticle.from(split)!!
    private val elsewhere = note(tags("https://keys.example.com/k"))
    private val elsewhereGated = GatedArticle.from(elsewhere)!!

    private val keys = FakePrefs()
    private val paid = FakePrefs()
    private val nostr = mockk<NostrService>(relaxed = true).also {
        every { it.activeHexPubkey } returns reader
        every { it.profiles } returns MutableStateFlow(
            mapOf(author to FeedProfile(author, lud16 = "a@example.com"), other to FeedProfile(other, lud16 = "o@example.com")),
        )
    }
    private val zaps = mockk<ZapSendService>()

    private fun service(): GatedArticleService {
        val context = mockk<Context>()
        every { context.getSharedPreferences("gated_article_keys", any()) } returns keys
        every { context.getSharedPreferences("gated_article_paid_shares", any()) } returns paid
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        return GatedArticleService(context, nostr, mockk<ConfigStore>(relaxed = true), zaps, scope).also { it.sleep = {} }
    }

    private fun noSigningOrPaying() {
        coVerify(exactly = 0) { nostr.signEventAsync(any(), any(), any(), any(), any(), any(), any(), any()) }
        coVerify(exactly = 0) { zaps.zapNote(any(), any(), any(), any(), any(), any()) }
    }

    // ── Stored keys (every gated article) ───────────────────────────

    @Test fun anArticleUnlockedBeforeStillOpens() = runBlocking {
        keys.strings[storedAt] = key
        assertEquals("# Whose life is this?\n\nThe full article — with ünïcode ⚡.", service().storedBody(elsewhere, elsewhereGated))
        assertEquals("# Whose life is this?\n\nThe full article — with ünïcode ⚡.", service().open(elsewhere, elsewhereGated))
        noSigningOrPaying()
    }

    @Test fun aStoredKeyThatNoLongerOpensIsDropped() {
        keys.strings[storedAt] = "0".repeat(64)
        assertNull(service().storedBody(elsewhere, elsewhereGated))
        assertFalse(storedAt in keys.strings)
        noSigningOrPaying()
    }

    // ── Non-Fanfares: never signs, asks or pays ─────────────────────

    @Test fun aNonFanfaresArticleNeverSignsRequestsOrPays() = runBlocking {
        val s = service()
        for (call in listOf<suspend () -> Unit>(
            { s.open(elsewhere, elsewhereGated) },
            { s.pay(elsewhere, elsewhereGated) },
            { s.waitForKey(elsewhere, elsewhereGated) },
        )) {
            try {
                call(); fail("should stay locked")
            } catch (e: GatedArticleService.UnlockError.NotUnlockable) {
            }
        }
        noSigningOrPaying()
        assertTrue(paid.sets.isEmpty())
        assertEquals(elsewhereGated.shares, s.unpaidShares(elsewhere, elsewhereGated))
    }

    // ── Paying (Fanfares) ───────────────────────────────────────────

    @Test fun aShareIsRecordedBeforeItsZapAndStaysRecordedOnATimeout() = runBlocking {
        val s = service()
        var recordedWhenZapped = false
        coEvery { zaps.zapNote(any(), any(), any(), any(), any(), any()) } coAnswers {
            recordedWhenZapped = s.unpaidShares(fanfares, fanfaresGated).isEmpty()
            Result.failure(ZapSendService.ZapError.PaymentFailed("NWC request timed out"))
        }
        try { s.pay(fanfares, fanfaresGated); fail("should throw") } catch (e: ZapSendService.ZapError.PaymentFailed) {}
        assertTrue("recorded before the zap went out", recordedWhenZapped)
        assertEquals(emptyList<GatedArticle.Share>(), s.unpaidShares(fanfares, fanfaresGated))
        assertTrue(s.hasPaid(fanfares, fanfaresGated))
    }

    @Test fun theZapCarriesTheArticleCoordinateAndTheAuthorsRelays() = runBlocking {
        coEvery { zaps.zapNote(any(), any(), any(), any(), any(), any()) } returns Result.success(Unit)
        service().pay(fanfares, fanfaresGated)
        coVerify(exactly = 1) {
            zaps.zapNote("n1", author, 42, "Unlocked with Nostr Vault", coordinate, listOf("wss://fanfares.nostr1.com"))
        }
    }

    @Test fun failuresBeforeTheWalletIsAskedUnrecordTheShare() = runBlocking {
        for (error in listOf(
            ZapSendService.ZapError.LnurlFailed(), ZapSendService.ZapError.InvoiceFailed(),
            ZapSendService.ZapError.SignFailed(), ZapSendService.ZapError.NoWallet(),
            ZapSendService.ZapError.PaymentFailed("Invalid NWC URI", notPaid = true),
            ZapSendService.ZapError.PaymentFailed("insufficient balance", notPaid = true),
        )) {
            val s = service()
            coEvery { zaps.zapNote(any(), any(), any(), any(), any(), any()) } returns Result.failure(error)
            try { s.pay(fanfares, fanfaresGated); fail("should throw") } catch (e: ZapSendService.ZapError) {}
            assertEquals(error.message, fanfaresGated.shares, s.unpaidShares(fanfares, fanfaresGated))
        }
    }

    @Test fun onlyPreWalletFailuresCountAsNotPaid() {
        assertFalse(GatedArticleService.failedBeforePaying(ZapSendService.ZapError.PaymentFailed("timeout")))
        assertTrue(GatedArticleService.failedBeforePaying(ZapSendService.ZapError.PaymentFailed("Encryption failed", notPaid = true)))
        assertFalse(GatedArticleService.failedBeforePaying(RuntimeException("socket closed")))
        assertTrue(GatedArticleService.failedBeforePaying(ZapSendService.ZapError.SignFailed()))
    }

    @Test fun aRecordedShareIsNeverOfferedOrPaidAgain() = runBlocking {
        val s = service()
        // The first share times out (maybe paid); the second is never reached.
        coEvery { zaps.zapNote(any(), author, any(), any(), any(), any()) } returns
            Result.failure(ZapSendService.ZapError.PaymentFailed("timeout"))
        try { s.pay(split, splitGated); fail("should throw") } catch (e: ZapSendService.ZapError) {}
        assertEquals(listOf(other), s.unpaidShares(split, splitGated).map { it.pubkey })

        coEvery { zaps.zapNote(any(), other, any(), any(), any(), any()) } returns Result.success(Unit)
        s.pay(split, splitGated)
        coVerify(exactly = 1) { zaps.zapNote(any(), author, any(), any(), any(), any()) }
        coVerify(exactly = 1) { zaps.zapNote(any(), other, any(), any(), any(), any()) }
        assertTrue(s.unpaidShares(split, splitGated).isEmpty())

        // Fully paid: paying again sends nothing.
        s.pay(split, splitGated)
        coVerify(exactly = 2) { zaps.zapNote(any(), any(), any(), any(), any(), any()) }
    }

    @Test fun walletRefusalsMoveNoMoneyButAFailedPaymentMayHave() {
        for (code in listOf("INSUFFICIENT_BALANCE", "QUOTA_EXCEEDED", "RATE_LIMITED", "RESTRICTED", "UNAUTHORIZED", "NOT_IMPLEMENTED")) {
            assertTrue(code, NWCWalletException(code, "no").refusedBeforePaying)
        }
        for (code in listOf("PAYMENT_FAILED", "INTERNAL", "OTHER")) {
            assertFalse(code, NWCWalletException(code, "no").refusedBeforePaying)
        }
    }

    @Test fun payAgainReoffersOnlyTheShareThatMayNotHavePaid() = runBlocking {
        val s = service()
        // The author's share is confirmed; the other times out (maybe paid).
        coEvery { zaps.zapNote(any(), author, any(), any(), any(), any()) } returns Result.success(Unit)
        coEvery { zaps.zapNote(any(), other, any(), any(), any(), any()) } returns
            Result.failure(ZapSendService.ZapError.PaymentFailed("timeout"))
        try { s.pay(split, splitGated); fail("should throw") } catch (e: ZapSendService.ZapError) {}
        assertTrue(s.unpaidShares(split, splitGated).isEmpty())
        assertTrue(s.hasUncertainShare(split, splitGated))

        s.forgetPaid(split, splitGated)
        assertEquals(listOf(other), s.unpaidShares(split, splitGated).map { it.pubkey })
        coEvery { zaps.zapNote(any(), other, any(), any(), any(), any()) } returns Result.success(Unit)
        s.pay(split, splitGated)
        coVerify(exactly = 1) { zaps.zapNote(any(), author, any(), any(), any(), any()) }
        coVerify(exactly = 2) { zaps.zapNote(any(), other, any(), any(), any(), any()) }
        assertFalse(s.hasUncertainShare(split, splitGated))

        // Every share confirmed: forgetting re-offers nothing.
        s.forgetPaid(split, splitGated)
        assertTrue(s.unpaidShares(split, splitGated).isEmpty())
    }

    @Test fun aPriceSplitTooManyWaysIsNeverPaidInApp() = runBlocking {
        val many = note(tags("https://api.fanfares.live/request-key",
            (1..500).map { listOf("zap", it.toString(16).padStart(64, '0'), "", "1") }))
        val manyGated = GatedArticle.from(many)!!
        assertEquals(500, manyGated.totalSats)
        assertFalse(manyGated.payableInApp)
        assertTrue(fanfaresGated.payableInApp)
        assertTrue(splitGated.payableInApp)
        try { service().pay(many, manyGated); fail("should throw") } catch (e: GatedArticleService.UnlockError.TooManyShares) {}
        coVerify(exactly = 0) { zaps.zapNote(any(), any(), any(), any(), any(), any()) }
        assertTrue(paid.sets.isEmpty())
    }

    @Test fun aMissingLightningAddressFailsBeforeAnyMoneyMoves() = runBlocking {
        every { nostr.profiles } returns MutableStateFlow(mapOf(author to FeedProfile(author, lud16 = "a@example.com")))
        val s = service()
        try { s.pay(split, splitGated); fail("should throw") } catch (e: GatedArticleService.UnlockError.NoLightningAddress) {}
        coVerify(exactly = 0) { zaps.zapNote(any(), any(), any(), any(), any(), any()) }
        assertEquals(splitGated.shares, s.unpaidShares(split, splitGated))
    }

    @Test fun paidSharesBelongToOneReader() = runBlocking {
        coEvery { zaps.zapNote(any(), any(), any(), any(), any(), any()) } returns Result.success(Unit)
        val s = service()
        s.pay(fanfares, fanfaresGated)
        every { nostr.activeHexPubkey } returns "d".repeat(64)
        assertEquals(fanfaresGated.shares, s.unpaidShares(fanfares, fanfaresGated))
    }
}

/** In-memory SharedPreferences: strings and string sets, apply and commit. */
private class FakePrefs : SharedPreferences {
    val strings = HashMap<String, String>()
    val sets = HashMap<String, Set<String>>()

    override fun getString(key: String, defValue: String?) = strings[key] ?: defValue
    override fun getStringSet(key: String, defValues: MutableSet<String>?): MutableSet<String>? =
        sets[key]?.toMutableSet() ?: defValues
    override fun contains(key: String) = key in strings || key in sets
    override fun getAll(): MutableMap<String, *> = (strings + sets).toMutableMap()
    override fun getInt(key: String, defValue: Int) = defValue
    override fun getLong(key: String, defValue: Long) = defValue
    override fun getFloat(key: String, defValue: Float) = defValue
    override fun getBoolean(key: String, defValue: Boolean) = defValue
    override fun registerOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) {}
    override fun unregisterOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) {}

    override fun edit(): SharedPreferences.Editor = object : SharedPreferences.Editor {
        val ops = mutableListOf<() -> Unit>()
        fun op(f: () -> Unit): SharedPreferences.Editor { ops += f; return this }
        override fun putString(key: String, value: String?) = op { if (value == null) strings.remove(key) else strings[key] = value }
        override fun putStringSet(key: String, values: MutableSet<String>?) =
            op { if (values == null) sets.remove(key) else sets[key] = values.toSet() }
        override fun remove(key: String) = op { strings.remove(key); sets.remove(key) }
        override fun clear() = op { strings.clear(); sets.clear() }
        override fun putInt(key: String, value: Int) = this
        override fun putLong(key: String, value: Long) = this
        override fun putFloat(key: String, value: Float) = this
        override fun putBoolean(key: String, value: Boolean) = this
        override fun commit(): Boolean { ops.forEach { it() }; ops.clear(); return true }
        override fun apply() { commit() }
    }
}
