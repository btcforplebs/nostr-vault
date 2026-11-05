package com.nostrvault.fips

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** What MeshPairingHello lets through to the session: only signed kind 21195s for this device, from someone else. */
class MeshPairingHelloTest {
    private val own = "a".repeat(64)
    private val other = "b".repeat(64)
    private val sub = "nvpair-0123456789ab"

    private fun frame(
        subId: String = sub,
        kind: Int = MeshPairing.HELLO_KIND,
        pubkey: String = other,
        p: String? = own,
        type: String = "EVENT",
    ): String {
        val tags = if (p == null) "[]" else "[[\"p\",\"$p\"]]"
        return "[\"$type\",\"$subId\",{\"id\":\"${"c".repeat(64)}\",\"pubkey\":\"$pubkey\",\"created_at\":1,\"kind\":$kind,\"tags\":$tags,\"content\":\"cipher\",\"sig\":\"${"d".repeat(128)}\"}]"
    }

    private fun read(message: String, verify: Boolean = true) =
        MeshPairingHello.eventFor(message, sub, own) { verify }

    @Test
    fun aSignedHelloForThisDeviceIsRead() {
        assertEquals(Triple(other, "cipher", "c".repeat(64)), read(frame()))
    }

    @Test
    fun theSenderIsLowerCased() {
        assertEquals(other, read(frame(pubkey = other.uppercase()))?.first)
    }

    @Test
    fun everythingElseIsDropped() {
        assertNull("bad signature", read(frame(), verify = false))
        assertNull("another subscription", read(frame(subId = "other")))
        assertNull("another kind", read(frame(kind = 1)))
        assertNull("from this device", read(frame(pubkey = own)))
        assertNull("addressed to someone else", read(frame(p = other)))
        assertNull("addressed to nobody", read(frame(p = null)))
        assertNull("not an EVENT", read(frame(type = "EOSE")))
        assertNull("short pubkey", read(frame(pubkey = "abc")))
        assertNull("not JSON", read("nope"))
    }

    @Test
    fun verifyIsAskedLast() {
        var asked = 0
        MeshPairingHello.eventFor(frame(kind = 1), sub, own) { asked++; true }
        assertEquals("a wrong kind never reaches the signature check", 0, asked)
    }
}
