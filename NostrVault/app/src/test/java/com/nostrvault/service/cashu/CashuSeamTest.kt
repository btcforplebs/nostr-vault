package com.nostrvault.service.cashu

import android.content.SharedPreferences
import com.nostrvault.service.NWCService
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.mockk
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.nio.file.Files

/** The engine-free parts: reply decoding, the mint order, the choice, the seam's routing. */
class CashuSeamTest {
    @Test fun replyResultAndErrors() {
        val r = CashuReply.parse("""{"ok":true,"result":{"total":5,"reserved":0,"in_flight":0,"warn":false}}""".toByteArray())
        val b = CashuReply.json.decodeFromJsonElement(CashuBalance.serializer(), r)
        assertEquals(5, b.total)
        assertNull(b.perMint)
        assertEquals("42", CashuReply.parse("""{"ok":true,"result":42}""".toByteArray()).jsonPrimitive.content)
        assertEquals(kotlinx.serialization.json.JsonNull, CashuReply.parse("""{"ok":true}""".toByteArray()))
        try {
            CashuReply.parse("""{"ok":false,"error":"wallet: x","code":"pending"}""".toByteArray())
            fail()
        } catch (e: CashuException) {
            assertEquals("pending", e.code)
            assertEquals("wallet: x", e.message)
            assertTrue(e.mayStillSettle)
            assertFalse(e.refusedBeforePaying)
        }
        for (bad in listOf("not json", "", "[1]")) {
            try {
                CashuReply.parse(bad.toByteArray())
                fail(bad)
            } catch (e: CashuException) {
                assertEquals("error", e.code)
            }
        }
    }

    @Test fun pendingOpDecodesStuck() {
        val ops = CashuReply.json.decodeFromString<List<CashuPendingOp>>(
            """[{"id":"a","kind":"melt","mint":"https://m","created":1},{"id":"b","kind":"melt","stuck":"bad change"}]""")
        assertTrue(ops[0].isUnsettled)
        assertFalse(ops[1].isUnsettled)
    }

    @Test fun payOrderBiggestFirstSkipsEmpty() {
        val b = CashuBalance(total = 30, perMint = mapOf("https://b" to 10, "https://a" to 10, "https://c" to 20, "https://z" to 0))
        assertEquals(listOf("https://c", "https://a", "https://b"), CashuWalletService.payOrder(b).map { it.first })
    }

    @Test fun onlyPreSpendRefusalsTryAnotherMint() {
        for (code in listOf("not_enough", "no_change", "unknown_mint")) assertTrue(code, CashuWalletService.triesNextMint(code))
        for (code in listOf("pending", "busy", "error", "already_spent", "not_paid")) assertFalse(code, CashuWalletService.triesNextMint(code))
    }

    @Test fun payZapsWithDefaultsToNwcPerAccount() {
        val prefs = MapPrefs()
        val choice = PayZapsWith { prefs }
        val a = "a".repeat(64)
        val b = "b".repeat(64)
        assertEquals(ZapWallet.NWC, choice.choice(a))
        assertNull(choice.stored(a))
        choice.set(ZapWallet.CASHU, a.uppercase())
        assertEquals(ZapWallet.CASHU, choice.choice(a))
        assertEquals(ZapWallet.NWC, choice.choice(b))
        prefs.map[choice.key(b)] = "lightning-bank"
        assertEquals(ZapWallet.NWC, choice.choice(b))
        choice.clear(a)
        assertEquals(ZapWallet.NWC, choice.choice(a))
        choice.set(ZapWallet.CASHU, "")
        assertEquals(ZapWallet.NWC, choice.choice(""))
    }

    @Test fun seamPaysNwcUnlessCashuChosenAndCashuFailsClosed() = runBlocking {
        val nwc = mockk<NWCService>()
        coEvery { nwc.payInvoice(any()) } returns "pre"
        val prefs = MapPrefs()
        val choice = PayZapsWith { prefs }
        val wallets = CashuWallets(Files.createTempDirectory("cashu-seam").toFile(), FailingEngine)
        val payer = ZapPayer(nwc, choice, wallets)
        val a = "c".repeat(64)
        assertEquals("pre", payer.pay("lnbc1", a))
        choice.set(ZapWallet.CASHU, a)
        try {
            payer.pay("lnbc2", a)
            fail("paid with a built-in wallet that isn't on this device")
        } catch (e: CashuException) {
            assertEquals("no_wallet", e.code)
            assertTrue(e.refusedBeforePaying)
        }
        coVerify(exactly = 0) { nwc.payInvoice("lnbc2") } // never falls back to NWC
        assertEquals("pre", payer.pay("lnbc3", a, pinned = ZapWallet.NWC))
    }

    /** The engine must not be reached in the seam tests. */
    private object FailingEngine : CashuEngine {
        override fun open(path: String): ByteArray = error("engine reached")
        override fun call(handle: Int, method: String, args: String): ByteArray = error("engine reached")
        override fun close(handle: Int) {}
    }
}

/** In-memory SharedPreferences: strings only, what PayZapsWith uses. */
private class MapPrefs : SharedPreferences {
    val map = HashMap<String, String>()
    override fun getAll(): MutableMap<String, *> = HashMap(map)
    override fun getString(key: String?, defValue: String?): String? = map[key] ?: defValue
    override fun getStringSet(key: String?, defValues: MutableSet<String>?): MutableSet<String>? = defValues
    override fun getInt(key: String?, defValue: Int) = defValue
    override fun getLong(key: String?, defValue: Long) = defValue
    override fun getFloat(key: String?, defValue: Float) = defValue
    override fun getBoolean(key: String?, defValue: Boolean) = defValue
    override fun contains(key: String?) = map.containsKey(key)
    override fun registerOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) {}
    override fun unregisterOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) {}
    override fun edit(): SharedPreferences.Editor = object : SharedPreferences.Editor {
        override fun putString(key: String, value: String?) = apply { if (value == null) map.remove(key) else map[key] = value }
        override fun putStringSet(key: String?, values: MutableSet<String>?) = this
        override fun putInt(key: String?, value: Int) = this
        override fun putLong(key: String?, value: Long) = this
        override fun putFloat(key: String?, value: Float) = this
        override fun putBoolean(key: String?, value: Boolean) = this
        override fun remove(key: String) = apply { map.remove(key) }
        override fun clear() = apply { map.clear() }
        override fun commit() = true
        override fun apply() {}
    }
}
