package com.nostrvault.util

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The wallet Send box, LNURL amount ranges and NIP-47 history decoding.
 * Mirrors iOS LightningPayTargetTests.swift case for case.
 */
class LightningPayTargetTest {

    // A real LUD-01 example: https://service.com/api?q=3fc3645b439ce8e7f2553a69e5267081d96dcd340693afabe04be7b0ccd178df
    private val lnurl = "LNURL1DP68GURN8GHJ7UM9WFMXJCM99E3K7MF0V9CXJ0M385EKVCENXC6R2C35XVUKXEFCV5MKVV34X5EKZD3EV56NYD3HXQURZEPEXEJXXEPNXSCRVWFNV9NXZCN9XQ6XYEFHVGCXXCMYXYMNSERXFQ5FNS"

    private fun parse(s: String) = LightningPayTarget.parse(s)
    private fun invoice(s: String) = LightningPayTarget.Invoice(s)

    @Test fun `invoice`() {
        assertEquals(invoice("lnbc2500u1pvjluez"), parse("lnbc2500u1pvjluez"))
        assertEquals(invoice("lnbc2500u1pvjluez"), parse("  LNBC2500U1PVJLUEZ\n"))
        assertEquals(invoice("lnbc2500u1pvjluez"), parse("lightning:lnbc2500u1pvjluez"))
        assertEquals(invoice("lnbc2500u1pvjluez"), parse("LIGHTNING:LNBC2500U1PVJLUEZ"))
        assertEquals(invoice("lnbc2500u1pvjluez"), parse("lightning://lnbc2500u1pvjluez"))
        assertEquals(invoice("lntb20m1pvjluez"), parse("lntb20m1pvjluez"))
    }

    @Test fun `BIP21 carries the lightning parameter`() {
        assertEquals(
            invoice("lnbc10u1pvjluez"),
            parse("bitcoin:bc1qxyz?amount=0.0001&lightning=LNBC10U1PVJLUEZ&label=x"),
        )
        // Percent-encoded parameter values decode.
        assertEquals(
            LightningPayTarget.Address("tips@example.com"),
            parse("bitcoin:bc1qxyz?lightning=tips%40example.com"),
        )
        // On-chain only: nothing this wallet can pay.
        assertNull(parse("bitcoin:bc1qxyz?amount=0.0001"))
    }

    @Test fun `lightning address`() {
        assertEquals(LightningPayTarget.Address("logen@getalby.com"), parse("Logen@getalby.com"))
        assertEquals(
            LightningPayTarget.Address("satoshi@walletofsatoshi.com"),
            parse(" lightning:satoshi@walletofsatoshi.com "),
        )
        assertEquals(
            LightningPayTarget.Address("first.last+tip@pay.example.co.uk"),
            parse("first.last+tip@pay.example.co.uk"),
        )
        assertNull(parse("no-domain@"))
        assertNull(parse("@domain.com"))
        assertNull(parse("user@localhost"))
        assertNull(parse("two@at@signs.com"))
        assertNull(parse("has space@domain.com"))
    }

    /** Address before invoice prefix: `lntbob@getalby.com` is a person, not testnet. */
    @Test fun `address that looks like an invoice prefix`() {
        assertEquals(LightningPayTarget.Address("lntbob@getalby.com"), parse("lntbob@getalby.com"))
        assertEquals(LightningPayTarget.Address("lnbc@pay.example.com"), parse("lnbc@pay.example.com"))
        // Not an address and not an invoice: bolt11 never contains '@'.
        assertNull(parse("lnbc@nodomain"))
    }

    @Test fun `bech32 LNURL`() {
        assertEquals(LightningPayTarget.Lnurl(lnurl.lowercase()), parse(lnurl))
        assertEquals(LightningPayTarget.Lnurl(lnurl.lowercase()), parse("lightning:$lnurl"))
    }

    /** What the send box hands LNURLService.resolve must decode to the service URL. */
    @Test fun `parsed bech32 LNURL decodes to its URL`() {
        val target = parse(lnurl) as LightningPayTarget.Lnurl
        assertEquals(
            "https://service.com/api?q=3fc3645b439ce8e7f2553a69e5267081d96dcd340693afabe04be7b0ccd178df",
            com.nostrvault.service.Bech32.decodeLNURL(target.bech32),
        )
    }

    @Test fun `LUD-17 links`() {
        assertEquals(
            LightningPayTarget.LnurlUrl("https://pay.example.com/lnurlp/abc"),
            parse("lnurlp://pay.example.com/lnurlp/abc"),
        )
        assertEquals(
            LightningPayTarget.LnurlUrl("https://atm.example.com/w?k1=1"),
            parse("lnurlw://atm.example.com/w?k1=1"),
        )
        assertEquals(
            LightningPayTarget.LnurlUrl("http://abcdef.onion/p"),
            parse("lnurlp://abcdef.onion/p"),
        )
        assertEquals(
            LightningPayTarget.LnurlUrl("https://pay.example.com/p"),
            parse("lightning:lnurlp://pay.example.com/p"),
        )
    }

    @Test fun `junk`() {
        assertNull(parse(""))
        assertNull(parse("   "))
        assertNull(parse("hello"))
        assertNull(parse("npub1vxlhjzeqjjhmqdy4e8sndt8kzklqlnxzew2mtt8mtakvalsckp3qa0gnvx"))
        assertNull(parse("https://example.com"))
    }

    // ── Amount range ──────────────────────────────────────────────

    @Test fun `amount range`() {
        val r = LNURLAmountRange(minMsat = 1_000, maxMsat = 100_000_000)
        assertEquals(LNURLAmountRange.Check.Ok(21_000), r.check(21))
        assertEquals(LNURLAmountRange.Check.Ok(1_000), r.check(1))
        assertEquals(LNURLAmountRange.Check.Ok(100_000_000), r.check(100_000))
        assertEquals(LNURLAmountRange.Check.TooLarge(100_000), r.check(100_001))
        assertEquals(LNURLAmountRange.Check.Invalid, r.check(0))
        assertEquals(LNURLAmountRange.Check.Invalid, r.check(null))
        assertFalse(r.isFixed)
    }

    /**
     * Bounds that are not whole sats round inwards, so the sat amount the
     * user is offered is always one the service will take.
     */
    @Test fun `fractional bounds round inwards`() {
        val r = LNURLAmountRange(minMsat = 1_500, maxMsat = 9_999)
        assertEquals(2L, r.minSats)
        assertEquals(9L, r.maxSats)
        assertEquals(LNURLAmountRange.Check.TooSmall(2), r.check(1))
        assertEquals(LNURLAmountRange.Check.Ok(2_000), r.check(2))
        assertEquals(LNURLAmountRange.Check.TooLarge(9), r.check(10))
    }

    /**
     * A long run of digits must not wrap: this check runs as the user types,
     * and a wrapped product reads as a small or even in-range amount.
     */
    @Test fun `huge amount does not overflow`() {
        val r = LNURLAmountRange(minMsat = 1_000, maxMsat = 100_000_000)
        assertEquals(LNURLAmountRange.Check.TooLarge(100_000), r.check(10_000_000_000_000_000L))
        assertEquals(LNURLAmountRange.Check.TooLarge(100_000), r.check(Long.MAX_VALUE))
        // 18_446_744_073_709_552 sats * 1000 wraps to 384 msat: inside a
        // range that starts at 1 msat. It must still be refused.
        val wide = LNURLAmountRange(minMsat = 1, maxMsat = 1_000_000)
        assertEquals(LNURLAmountRange.Check.TooLarge(1_000), wide.check(18_446_744_073_709_552L))
    }

    @Test fun `fixed amount`() {
        assertTrue(LNURLAmountRange(minMsat = 50_000, maxMsat = 50_000).isFixed)
    }

    @Test fun `plain text metadata`() {
        assertEquals(
            "Tips for Logen",
            lnurlPlainTextMetadata("""[["text/identifier","logen@getalby.com"],["text/plain","Tips for Logen"]]"""),
        )
        assertNull(lnurlPlainTextMetadata("""[["text/identifier","x@y.com"]]"""))
        assertNull(lnurlPlainTextMetadata("not json"))
    }

    // ── History ───────────────────────────────────────────────────

    private fun obj(s: String): JsonObject = Json.parseToJsonElement(s).jsonObject

    @Test fun `transaction decoding`() {
        val t = WalletTransaction.fromNip47(obj("""{
            "type": "incoming", "state": "settled", "invoice": "lnbc1",
            "description": "  coffee ", "payment_hash": "abc", "amount": 21000,
            "fees_paid": 0, "created_at": 1700000000, "settled_at": 1700000005
        }"""))
        assertEquals("abc", t?.id)
        assertEquals(WalletTransaction.Direction.INCOMING, t?.direction)
        assertEquals(WalletTransaction.State.SETTLED, t?.state)
        assertEquals(21L, t?.amountSats)
        assertEquals("coffee", t?.description)
        assertEquals(1_700_000_000L, t?.createdAt)
        assertEquals(1_700_000_005L, t?.settledAt)
    }

    /** Wallets disagree on number types; a string or double amount must not read as zero. */
    @Test fun `loose number types`() {
        val t = WalletTransaction.fromNip47(obj("""{
            "type": "outgoing", "payment_hash": "h", "amount": "5000",
            "fees_paid": 2000.0, "created_at": 1700000000.0
        }"""))
        assertEquals(5L, t?.amountSats)
        assertEquals(2L, t?.feeSats)
        assertEquals(1_700_000_000L, t?.createdAt)
        assertEquals(WalletTransaction.Direction.OUTGOING, t?.direction)
    }

    /** No `state` field (older NIP-47 wallets): settled_at decides. */
    @Test fun `state falls back to settled_at`() {
        val settled = WalletTransaction.fromNip47(obj("""{"type":"outgoing","amount":1000,"created_at":1,"settled_at":2}"""))
        val pending = WalletTransaction.fromNip47(obj("""{"type":"outgoing","amount":1000,"created_at":1}"""))
        assertEquals(WalletTransaction.State.SETTLED, settled?.state)
        assertEquals(WalletTransaction.State.PENDING, pending?.state)
    }

    @Test fun `id falls back to invoice then type-created-amount`() {
        assertEquals(
            "lnbc1x",
            WalletTransaction.fromNip47(obj("""{"type":"incoming","invoice":"lnbc1x","amount":3000,"created_at":7}"""))?.id,
        )
        assertEquals(
            "incoming-7-3",
            WalletTransaction.fromNip47(obj("""{"type":"incoming","amount":3000,"created_at":7}"""))?.id,
        )
    }

    /** NaN and 1e300 read as absent, not as 0-by-accident or Long.MAX_VALUE. */
    @Test fun `out of range numbers read as absent`() {
        assertEquals(0L, WalletTransaction.fromNip47(obj("""{"type":"incoming","created_at":1,"amount":"NaN"}"""))?.amountSats)
        assertEquals(0L, WalletTransaction.fromNip47(obj("""{"type":"incoming","created_at":1,"amount":1e300}"""))?.amountSats)
        assertEquals(0L, WalletTransaction.fromNip47(obj("""{"type":"incoming","created_at":1,"amount":"1e300"}"""))?.amountSats)
        assertEquals(0L, WalletTransaction.fromNip47(obj("""{"type":"outgoing","created_at":1,"amount":1,"fees_paid":"Infinity"}"""))?.feeSats)
        // A time that does not fit is no time, so the entry is dropped.
        assertNull(WalletTransaction.fromNip47(obj("""{"type":"incoming","created_at":1e300}""")))
        assertNull(WalletTransaction.fromNip47(obj("""{"type":"incoming","created_at":1,"settled_at":"NaN"}"""))?.settledAt)
    }

    @Test fun `unusable entries are dropped`() {
        assertNull(WalletTransaction.fromNip47(obj("""{"amount":1000,"created_at":1}""")))
        assertNull(WalletTransaction.fromNip47(obj("""{"type":"sideways","amount":1000,"created_at":1}""")))
        assertNull(WalletTransaction.fromNip47(obj("""{"type":"incoming","amount":1000}""")))
    }

    @Test fun `empty description is null`() {
        assertNull(WalletTransaction.fromNip47(obj("""{"type":"incoming","created_at":1,"description":"   "}"""))?.description)
    }

    @Test fun `merge dedupes and sorts newest first`() {
        fun tx(id: String, t: Long) = WalletTransaction(
            id = id, direction = WalletTransaction.Direction.INCOMING,
            state = WalletTransaction.State.SETTLED, amountSats = 1, feeSats = 0,
            description = null, createdAt = t, settledAt = null,
        )
        val merged = WalletTransaction.merge(
            listOf(tx("a", 30), tx("b", 20)),
            listOf(tx("b", 20), tx("c", 25), tx("d", 10)),
        )
        assertEquals(listOf("a", "c", "b", "d"), merged.map { it.id })
    }
}
