package com.nostrvault.util

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Who a wallet-history zap came from: zap request parsing, the BOLT-11
 * payment hash, and matching receipts to transactions.
 * Mirrors iOS ZapHistoryTests.swift case for case.
 */
class ZapHistoryTest {

    // BOLT-11 spec example; its payment hash is 0001020304…0102.
    private val specInvoice = "lnbc1pvjluezsp5zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygspp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdpl2pkx2ctnv5sxxmmwwd5kgetjypeh2ursdae8g6twvus8g6rfwvs8qun0dfjkxaq9qrsgq357wnc5r2ueh7ck6q93dj32dlqnls087fxdwk8qakdyafkq3yap9us6v52vjjsrvywa6rt52cm9r9zqt8r2t7mlcwspyetp5h2tztugp9lfyql"
    private val specHash = "0001020304050607080900010203040506070809000102030405060708090102"

    private val alice = "a".repeat(64)
    private val bob = "b".repeat(64)
    private val post = "e".repeat(64)

    @Test fun `payment hash`() {
        assertEquals(specHash, Bolt11.paymentHash(specInvoice))
        assertEquals(specHash, Bolt11.paymentHash(specInvoice.uppercase()))
        // Only the data part is read, so a stray prefix does not matter.
        assertEquals(specHash, Bolt11.paymentHash("lightning:$specInvoice"))
        assertNull(Bolt11.paymentHash("lnbc1qqqq"))
        assertNull(Bolt11.paymentHash("not an invoice"))
    }

    private fun zapRequest(from: String, to: String, post: String?, content: String = "", anon: Boolean = false): String {
        val obj = buildJsonObject {
            put("kind", 9734)
            put("pubkey", from)
            put("content", content)
            put("tags", buildJsonArray {
                add(buildJsonArray { add(jsonString("p")); add(jsonString(to)) })
                add(buildJsonArray { add(jsonString("amount")); add(jsonString("21000")) })
                add(buildJsonArray { add(jsonString("relays")); add(jsonString("wss://x")) })
                if (post != null) add(buildJsonArray { add(jsonString("e")); add(jsonString(post)) })
                if (anon) add(buildJsonArray { add(jsonString("anon")) })
            })
            put("created_at", 1)
            put("id", "x")
            put("sig", "y")
        }
        return obj.toString()
    }

    private fun jsonString(s: String) = kotlinx.serialization.json.JsonPrimitive(s)

    private fun nip47(vararg pairs: Pair<String, Any>): WalletTransaction? {
        val obj: JsonObject = buildJsonObject {
            for ((k, v) in pairs) when (v) {
                is String -> put(k, v)
                is Number -> put(k, v)
                else -> error("unsupported")
            }
        }
        return WalletTransaction.fromNip47(obj)
    }

    @Test fun `zap request parsing`() {
        val d = ZapDetail.fromZapRequest(zapRequest(from = alice, to = bob, post = post, content = " great shot "))
        assertEquals(alice, d?.senderPubkey)
        assertEquals(bob, d?.recipientPubkey)
        assertEquals(post, d?.postId)
        assertEquals("great shot", d?.comment)
        assertEquals(false, d?.isAnonymous)
    }

    @Test fun `profile zap has no post`() {
        val d = ZapDetail.fromZapRequest(zapRequest(from = alice, to = bob, post = null))
        assertNull(d?.postId)
        assertNull(d?.comment)
    }

    @Test fun `plain descriptions are not zaps`() {
        assertNull(ZapDetail.fromZapRequest("Payment to logen"))
        assertNull(ZapDetail.fromZapRequest("""{"kind":1,"pubkey":"a"}"""))
        assertNull(ZapDetail.fromZapRequest("{not json"))
    }

    @Test fun `counterparty`() {
        val d = ZapDetail.fromZapRequest(zapRequest(from = alice, to = bob, post = post))!!
        assertEquals(alice, d.counterparty(bob, WalletTransaction.Direction.INCOMING))
        assertEquals(bob, d.counterparty(alice, WalletTransaction.Direction.OUTGOING))
        val anon = ZapDetail.fromZapRequest(zapRequest(from = alice, to = bob, post = post, anon = true))!!
        // An anonymous zap's key is throwaway, not a person.
        assertNull(anon.counterparty(bob, WalletTransaction.Direction.INCOMING))
    }

    /**
     * A wallet that hands back the zap request as the description: the row
     * gets the zap, and never shows the raw JSON.
     */
    @Test fun `transaction with zap request description`() {
        val tx = nip47(
            "type" to "incoming", "created_at" to 1, "amount" to 21_000,
            "payment_hash" to specHash, "description" to zapRequest(from = alice, to = bob, post = post),
        )
        assertEquals(alice, tx?.zap?.senderPubkey)
        assertNull(tx?.description)
    }

    @Test fun `payment hash falls back to the invoice`() {
        val tx = nip47("type" to "outgoing", "created_at" to 1, "invoice" to specInvoice)
        assertEquals(specHash, tx?.paymentHash)
    }

    @Test fun `receipt parsing and matching`() {
        val receipt = ZapReceipt.fromTags(listOf(
            listOf("p", bob), listOf("e", post), listOf("bolt11", specInvoice.uppercase()),
            listOf("description", zapRequest(from = alice, to = bob, post = post, content = "nice")),
        ))
        assertEquals(specHash, receipt?.paymentHash)

        val byHash = nip47("type" to "incoming", "created_at" to 1, "payment_hash" to specHash.uppercase())!!
        val byInvoice = WalletTransaction(
            id = "inv", direction = WalletTransaction.Direction.INCOMING, state = WalletTransaction.State.SETTLED,
            amountSats = 1, feeSats = 0, description = null, createdAt = 1, settledAt = null,
            paymentHash = null, invoice = specInvoice,
        )
        val other = nip47("type" to "incoming", "created_at" to 1, "payment_hash" to "f".repeat(64))!!

        val m = ZapReceipt.match(listOf(byHash, byInvoice, other), listOf(receipt!!))
        assertEquals("nice", m[byHash.id]?.comment)
        assertEquals(alice, m[byInvoice.id]?.senderPubkey)
        assertNull(m[other.id])
    }

    /**
     * A forger can copy a real receipt's bolt11 into a receipt of their own.
     * Two receipts that disagree about one payment: neither is shown.
     */
    @Test fun `conflicting receipts for one payment show neither`() {
        val real = ZapReceipt.fromTags(listOf(listOf("bolt11", specInvoice),
            listOf("description", zapRequest(from = alice, to = bob, post = post, content = "nice"))))!!
        val fake = ZapReceipt.fromTags(listOf(listOf("bolt11", specInvoice),
            listOf("description", zapRequest(from = alice, to = bob, post = post, content = "refund me at evil"))))!!
        val byHash = nip47("type" to "incoming", "created_at" to 1, "payment_hash" to specHash)!!
        val byInvoice = WalletTransaction(
            id = "inv", direction = WalletTransaction.Direction.INCOMING, state = WalletTransaction.State.SETTLED,
            amountSats = 1, feeSats = 0, description = null, createdAt = 1, settledAt = null,
            paymentHash = null, invoice = specInvoice,
        )
        assertEquals(emptyMap<String, ZapDetail>(), ZapReceipt.match(listOf(byHash, byInvoice), listOf(real, fake)))
        // The same receipt twice (it came back from two relays) is no conflict.
        assertEquals("nice", ZapReceipt.match(listOf(byHash), listOf(real, real))[byHash.id]?.comment)
    }

    /** The raw request is kept so the service can check its signature. */
    @Test fun `zap detail keeps the request text`() {
        val json = zapRequest(from = alice, to = bob, post = null)
        assertEquals(json, ZapDetail.fromZapRequest("  $json\n")?.requestJson)
    }

    @Test fun `receipt missing parts is dropped`() {
        assertNull(ZapReceipt.fromTags(listOf(listOf("bolt11", specInvoice))))
        assertNull(ZapReceipt.fromTags(listOf(listOf("description", zapRequest(from = alice, to = bob, post = null)))))
    }

    /** Receipt tags come straight off the wire as JSON; non-string entries are skipped, not fatal. */
    @Test fun `tags parse leniently`() {
        val obj = Json.parseToJsonElement("""{"tags":[["p","x"],["bad",1],"junk",["anon"]]}""").jsonObject
        assertEquals(listOf(listOf("p", "x"), listOf("anon")), ZapDetail.parseTags(obj["tags"]))
        assertFalse(ZapDetail.parseTags(null).isNotEmpty())
    }
}
