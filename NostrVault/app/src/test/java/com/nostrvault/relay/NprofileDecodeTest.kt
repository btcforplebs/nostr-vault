package com.nostrvault.relay

import com.nostrvault.ui.components.NostrMentions
import com.nostrvault.ui.navigation.BridgeEntityDecoder
import com.nostrvault.ui.navigation.DeepLinkRouter
import com.nostrvault.ui.navigation.Screen
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** nprofile → pubkey: the first 32-byte type-0 entry or nothing (iOS #186). */
class NprofileDecodeTest {

    // NIP-19's own example.
    private val specNprofile =
        "nprofile1qqsrhuxx8l9ex335q7he0f09aej04zpazpl0ne2cgukyawd24mayt8gpp4mhxue69uhhytnc9e3k7mgpz4mhxue69uhkg6nzv9ejuumpv34kytnrdaksjlyr9p"
    private val specPubkey = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"

    private val keyA = ByteArray(32) { 0xAA.toByte() }
    private val keyB = ByteArray(32) { 0xBB.toByte() }

    @Test fun `spec example decodes to its pubkey`() {
        assertEquals(specPubkey, HavenBridge.decodeNprofilePubkey(specNprofile))
    }

    @Test fun `a short type-0 entry is not a pubkey`() {
        assertNull(HavenBridge.decodeNprofilePubkey(nprofile(tlv(0, ByteArray(16) { 1 }))))
        assertNull(HavenBridge.decodeNprofile(nprofile(tlv(0, ByteArray(16) { 1 }))))
    }

    @Test fun `a long type-0 entry is not a pubkey`() {
        assertNull(HavenBridge.decodeNprofilePubkey(nprofile(tlv(0, ByteArray(33) { 1 }))))
    }

    @Test fun `first 32-byte type-0 entry wins`() {
        val hex = HavenBridge.decodeNprofilePubkey(nprofile(tlv(0, keyA) + tlv(0, keyB)))
        assertEquals("aa".repeat(32), hex)
    }

    @Test fun `a bad entry before the real key is skipped`() {
        val hex = HavenBridge.decodeNprofilePubkey(nprofile(tlv(0, ByteArray(20)) + tlv(0, keyB)))
        assertEquals("bb".repeat(32), hex)
    }

    @Test fun `mention in note text resolves to the hex pubkey`() {
        assertEquals(listOf(specPubkey), NostrMentions.mentionedPubkeys("hi nostr:$specNprofile"))
    }

    /** A `nostr:nprofile1…` link used to route to a profile named by the decoder's JSON. */
    @Test fun `nostr nprofile link opens the profile by hex pubkey`() {
        val target = DeepLinkRouter.fromUri("nostr:$specNprofile", BridgeEntityDecoder)
        assertEquals(Screen.Profile.createRoute(specPubkey), target?.route)
    }

    private fun tlv(type: Int, value: ByteArray) = byteArrayOf(type.toByte(), value.size.toByte()) + value

    private fun nprofile(payload: ByteArray): String = bech32("nprofile", payload)

    private fun bech32(hrp: String, payload: ByteArray): String {
        val charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
        val data = mutableListOf<Int>()
        var acc = 0
        var bits = 0
        for (b in payload) {
            acc = (acc shl 8) or (b.toInt() and 0xFF)
            bits += 8
            while (bits >= 5) { bits -= 5; data.add((acc shr bits) and 31) }
        }
        if (bits > 0) data.add((acc shl (5 - bits)) and 31)
        val values = hrp.map { it.code shr 5 } + 0 + hrp.map { it.code and 31 } + data + List(6) { 0 }
        val mod = polymod(values) xor 1
        val checksum = (0 until 6).map { (mod shr (5 * (5 - it))) and 31 }
        return hrp + "1" + (data + checksum).joinToString("") { charset[it].toString() }
    }

    private fun polymod(values: List<Int>): Int {
        val gen = intArrayOf(0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3)
        var chk = 1
        for (v in values) {
            val top = chk shr 25
            chk = ((chk and 0x1ffffff) shl 5) xor v
            for (i in 0 until 5) if ((top shr i) and 1 == 1) chk = chk xor gen[i]
        }
        return chk
    }
}
