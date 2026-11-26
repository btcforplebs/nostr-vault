package com.nostrvault.service.cashu

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.nio.file.Files

/**
 * Against the real engine (a host libhaven.dylib with HavenBridgeJNI.c compiled
 * in, so the JNI functions are under test too) and the local test mint
 * (haven-go/wallet/swift_harness_test.go). scripts/cashu-android-test.sh sets
 * CASHU_LIBHAVEN_DYLIB and CASHU_HARNESS; without them these tests are skipped.
 */
class CashuWalletServiceTest {
    @Serializable private data class Harness(val mint: String, val control: String)

    private lateinit var harness: Harness
    private lateinit var base: File
    private lateinit var wallets: CashuWallets

    @Before fun setUp() {
        val lib = System.getenv("CASHU_LIBHAVEN_DYLIB")
        val file = System.getenv("CASHU_HARNESS")?.let(::File)
        assumeTrue("no test mint: run scripts/cashu-android-test.sh", lib != null && file != null && file.exists())
        loadOnce(lib!!)
        harness = CashuReply.json.decodeFromString(Harness.serializer(), file!!.readText())
        base = Files.createTempDirectory("cashu-android").toFile()
        wallets = CashuWallets(base)
    }

    @After fun tearDown() {
        if (::base.isInitialized) base.deleteRecursively()
    }

    private fun control(path: String): String {
        val conn = URL(harness.control + path).openConnection() as HttpURLConnection
        assertEquals(path, 200, conn.responseCode)
        return conn.inputStream.bufferedReader().readText()
    }

    private fun newAccount(): String = (1..32).joinToString("") { "%02x".format((0..255).random()) }

    private suspend fun funded(sats: Long): CashuWalletService {
        val w = wallets.wallet(newAccount(), create = true)
        assertTrue(w.addMint(harness.mint).sat)
        val quote = w.requestMint(harness.mint, sats)
        try {
            w.claimMint(quote.id)
            fail("claimed an unpaid quote")
        } catch (e: CashuException) {
            assertEquals("not_paid", e.code)
        }
        control("/pay?quote=${quote.id}")
        assertEquals(sats, w.claimMint(quote.id))
        return w
    }

    private suspend fun expectCode(code: String, block: suspend () -> Unit): CashuException {
        try {
            block()
        } catch (e: CashuException) {
            assertEquals(code, e.code)
            return e
        }
        fail("expected $code")
        throw AssertionError()
    }

    @Test fun payInvoiceMeltsAndKeepsChange() = runBlocking {
        val w = funded(100)
        val paid = w.payInvoice(control("/invoice?amount=30"))
        // 30 to the invoice, 1 the Lightning fee; the rest of the 4 sat reserve comes back as change.
        assertEquals(31, paid.spent - paid.change)
        val after = w.balance()
        assertEquals(69, after.total)
        assertEquals(69L, after.perMint?.get(harness.mint))
    }

    @Test fun notEnoughSpendsNothing() = runBlocking {
        val w = funded(50)
        val e = expectCode("not_enough") { w.payInvoice(control("/invoice?amount=48")) } // 48 + 4 reserve > 50
        assertFalse(e.mayStillSettle)
        assertTrue(e.refusedBeforePaying)
        assertEquals(50, w.balance().total)
    }

    @Test fun pendingMeltBlocksEveryNewPayment() = runBlocking {
        val w = funded(100)
        control("/melt-pending?on=1")
        try {
            val invoice = control("/invoice?amount=10")
            val e = expectCode("pending") { w.payInvoice(invoice) }
            assertTrue(e.mayStillSettle)
            assertTrue(w.balance().total < 100)
            assertEquals(1, w.unsettledCount())
            // A retry of the same invoice, or any other, waits for that one to settle.
            expectCode("busy") { w.payInvoice(invoice) }
            expectCode("busy") { w.payInvoice(control("/invoice?amount=5")) }
            assertEquals(1, w.unsettledCount())
        } finally {
            control("/melt-pending?on=0")
        }
    }

    @Test fun stuckOpDoesNotBlockPayments() = runBlocking {
        val w = funded(100)
        control("/no-restore?on=1")
        control("/bad-dleq?on=1")
        try {
            // Paid, but the change comes back unusable: the op is kept, stuck.
            expectCode("pending") { w.payInvoice(control("/invoice?amount=10")) }
            control("/bad-dleq?on=0")
            val ops = w.pending()
            assertEquals(1, ops.size)
            assertFalse(ops[0].isUnsettled)
            val paid = w.payInvoice(control("/invoice?amount=5"))
            assertTrue(paid.spent >= 5)
            assertEquals(1, w.pending().size) // the stuck op is still kept
        } finally {
            control("/bad-dleq?on=0")
            control("/no-restore?on=0")
        }
    }

    @Test fun emptyWalletRefuses() = runBlocking {
        val w = wallets.wallet(newAccount(), create = true)
        w.addMint(harness.mint)
        expectCode("not_enough") { w.payInvoice(control("/invoice?amount=5")) }
        Unit
    }

    @Test fun payingNeverCreatesAWallet() {
        val account = newAccount()
        try {
            wallets.wallet(account)
            fail("opened a wallet that doesn't exist")
        } catch (e: CashuException) {
            assertEquals("no_wallet", e.code)
        }
        assertFalse(wallets.exists(account))
        assertFalse(wallets.fileFor(account).exists())
        try {
            wallets.wallet("npub1notahex", create = true)
            fail("opened a wallet for a non-hex account")
        } catch (e: CashuException) {
            assertEquals("no_wallet", e.code)
        }
    }

    @Test fun sameAccountSameWalletAndMemoUnicode() = runBlocking {
        val w = funded(21)
        assertSame(w, wallets.wallet(w.accountHex.uppercase()))
        assertTrue(wallets.exists(w.accountHex))
        // Emoji in the args survive the JNI byte path (modified UTF-8 would break them).
        val r = w.call("send", kotlinx.serialization.json.buildJsonObject {
            put("mint", kotlinx.serialization.json.JsonPrimitive(harness.mint))
            put("amount", kotlinx.serialization.json.JsonPrimitive(1))
            put("memo", kotlinx.serialization.json.JsonPrimitive("thanks 🤙"))
        })
        assertTrue(r.toString().isNotEmpty())
    }

    companion object {
        @Volatile private var loaded = false
        @Synchronized private fun loadOnce(path: String) {
            if (!loaded) CashuNative.loadForTests(path)
            loaded = true
        }
    }
}
