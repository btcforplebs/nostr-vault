package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** [QuoteRef.coordinateFromNaddrTlv]: every byte of an naddr comes from whoever sent the link. */
class NaddrTlvTest {
    private val author = ByteArray(32) { 0x22 }
    private val authorHex = "22".repeat(32)

    private fun tlv(type: Int, value: ByteArray) = byteArrayOf(type.toByte(), value.size.toByte()) + value
    private fun kind(k: Int) = tlv(3, byteArrayOf((k ushr 24).toByte(), (k ushr 16).toByte(), (k ushr 8).toByte(), k.toByte()))
    private fun d(s: String) = tlv(0, s.toByteArray(Charsets.UTF_8))
    private val pk = tlv(2, author)

    @Test
    fun `reads kind, author and d tag`() {
        assertEquals(
            QuoteRef.Coordinate(30023, authorHex, "my-article"),
            QuoteRef.coordinateFromNaddrTlv(d("my-article") + pk + kind(30023)),
        )
    }

    @Test
    fun `a zero-length d is a real empty d tag and still names an event`() {
        assertEquals(QuoteRef.Coordinate(30023, authorHex, ""), QuoteRef.coordinateFromNaddrTlv(tlv(0, ByteArray(0)) + pk + kind(30023)))
    }

    @Test
    fun `a d tag that is not valid UTF-8 names nothing, not the empty d tag`() {
        val bad = tlv(0, byteArrayOf(0x61, 0xC3.toByte(), 0x28))
        assertNull(QuoteRef.coordinateFromNaddrTlv(bad + pk + kind(30023)))
        assertNull(QuoteRef.coordinateFromNaddrTlv(tlv(0, byteArrayOf(0xFF.toByte())) + pk + kind(30023)))
    }

    @Test
    fun `a leading byte-order mark is kept, so it cannot name the plain d tag`() {
        val bom = tlv(0, byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte(), 0x78))
        assertEquals("﻿x", QuoteRef.coordinateFromNaddrTlv(bom + pk + kind(30023))!!.dTag)
    }

    @Test
    fun `non-ASCII and route characters survive as text`() {
        assertEquals("a/b?c#d%e&f é", QuoteRef.coordinateFromNaddrTlv(d("a/b?c#d%e&f é") + pk + kind(30023))!!.dTag)
    }

    @Test
    fun `missing author or kind names nothing, so no unbounded fetch`() {
        assertNull(QuoteRef.coordinateFromNaddrTlv(d("x") + kind(30023)))
        assertNull(QuoteRef.coordinateFromNaddrTlv(d("x") + pk))
        // Wrong-length author or kind entries are not read as one.
        assertNull(QuoteRef.coordinateFromNaddrTlv(d("x") + tlv(2, ByteArray(31)) + kind(30023)))
        assertNull(QuoteRef.coordinateFromNaddrTlv(d("x") + pk + tlv(3, byteArrayOf(0x75, 0x17))))
    }

    @Test
    fun `the relay hint is skipped and changes nothing`() {
        val hint = tlv(1, "wss://attacker.example".toByteArray())
        assertEquals(
            QuoteRef.coordinateFromNaddrTlv(d("x") + pk + kind(30023)),
            QuoteRef.coordinateFromNaddrTlv(hint + d("x") + hint + pk + kind(30023)),
        )
    }

    @Test
    fun `truncated or repeated entries name nothing`() {
        val ok = d("x") + pk + kind(30023)
        assertNull(QuoteRef.coordinateFromNaddrTlv(ok + byteArrayOf(0, 10, 0x61)))
        assertNull(QuoteRef.coordinateFromNaddrTlv(ok + byteArrayOf(0)))
        assertNull(QuoteRef.coordinateFromNaddrTlv(ok + d("y")))
        assertNull(QuoteRef.coordinateFromNaddrTlv(ok + tlv(2, ByteArray(32) { 0x33 })))
        assertNull(QuoteRef.coordinateFromNaddrTlv(ok + kind(30024)))
        assertNull(QuoteRef.coordinateFromNaddrTlv(ByteArray(0)))
    }

    @Test
    fun `a d tag at the 255-byte TLV maximum is read whole`() {
        val long = "z".repeat(255)
        assertEquals(long, QuoteRef.coordinateFromNaddrTlv(d(long) + pk + kind(30023))!!.dTag)
    }

    @Test
    fun `only addressable kinds may be opened from a link`() {
        listOf(30000, 30023, 30311, 39999).forEach { assertEquals(true, QuoteRef.isLinkableKind(it)) }
        listOf(0, 1, 3, 4, 1059, 10002, 29999, 40000, -1).forEach { assertEquals(false, QuoteRef.isLinkableKind(it)) }
    }
}
