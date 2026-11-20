package com.nostrvault.util

import com.nostrvault.data.model.FeedProfile
import com.nostrvault.relay.HavenBridge
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.math.BigInteger
import java.security.SecureRandom

/**
 * Every key here is generated in the test run (random 32 bytes); no real
 * key is in this file.
 */
class SecretKeyLeakTest {

    @After fun tearDown() = PublicKeyRegistry.clearForTest()

    private fun freshSecretHex(): String {
        val bytes = ByteArray(32)
        SecureRandom().nextBytes(bytes)
        bytes[0] = (bytes[0].toInt() and 0x7f).toByte() // always below the curve order
        if (bytes.all { it == 0.toByte() }) bytes[31] = 1
        return bytes.joinToString("") { "%02x".format(it) }
    }

    private fun freshNsec(): Pair<String, String> {
        val hex = freshSecretHex()
        return hex to HavenBridge.encodeNsec(hex)!!
    }

    /** Swaps one data character for another, so the checksum no longer holds. */
    private fun corrupt(nsec: String): String {
        val i = 20
        val c = if (nsec[i] == 'q') 'p' else 'q'
        return nsec.substring(0, i) + c + nsec.substring(i + 1)
    }

    @Test fun aValidKeyIsFound() {
        val (_, nsec) = freshNsec()
        assertTrue(SecretKeyLeak.containsSecretKey(nsec))
        assertTrue(SecretKeyLeak.containsSecretKey("my name is $nsec ok"))
        assertTrue(SecretKeyLeak.containsSecretKey("name$nsec"))
    }

    @Test fun theNostrUriFormIsFound() {
        val (_, nsec) = freshNsec()
        assertTrue(SecretKeyLeak.containsSecretKey("nostr:$nsec"))
    }

    @Test fun anUppercaseKeyIsFoundButMixedCaseIsNot() {
        val (_, nsec) = freshNsec()
        assertTrue(SecretKeyLeak.containsSecretKey(nsec.uppercase()))
        val mixed = nsec.substring(0, 30) + nsec.substring(30).uppercase()
        assertFalse(SecretKeyLeak.containsSecretKey(mixed))
    }

    @Test fun aBadChecksumIsIgnored() {
        val (_, nsec) = freshNsec()
        assertFalse(SecretKeyLeak.containsSecretKey(corrupt(nsec)))
    }

    @Test fun aTruncatedKeyIsIgnored() {
        val (_, nsec) = freshNsec()
        assertFalse(SecretKeyLeak.containsSecretKey(nsec.dropLast(1)))
        assertFalse(SecretKeyLeak.containsSecretKey(nsec.take(50)))
    }

    @Test fun thePrefixAloneIsIgnored() {
        assertFalse(SecretKeyLeak.containsSecretKey("nsec1"))
        assertFalse(SecretKeyLeak.containsSecretKey("paste your nsec1… here"))
        assertFalse(SecretKeyLeak.containsSecretKey("insecure"))
        assertFalse(SecretKeyLeak.containsSecretKey(null))
    }

    @Test fun anNpubIsNotASecretKey() {
        val hex = freshSecretHex()
        assertFalse(SecretKeyLeak.containsSecretKey(HavenBridge.encodeNpub(hex)))
    }

    @Test fun aKeyAfterABrokenOneIsStillFound() {
        val (_, a) = freshNsec()
        val (_, b) = freshNsec()
        assertTrue(SecretKeyLeak.containsSecretKey("${corrupt(a)}$b"))
        assertTrue(SecretKeyLeak.containsSecretKey("nsec1$b"))
    }

    @Test fun theTestCurveMatchesBip340() {
        // BIP-340 test vector 0: secret key 3.
        assertEquals(
            "f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9",
            TestSecp256k1.xOnly("0000000000000000000000000000000000000000000000000000000000000003"),
        )
    }

    @Test fun theDerivedPubkeyIsTheKeysOwn() {
        val (hex, nsec) = freshNsec()
        val (hex2, nsec2) = freshNsec()
        val got = SecretKeyLeak.derivedPubkeys("name: $nsec, about: nostr:$nsec2, again $nsec", TestSecp256k1::xOnly)
        assertEquals(listOf(TestSecp256k1.xOnly(hex), TestSecp256k1.xOnly(hex2)), got)
    }

    @Test fun noDerivationWithoutAValidKey() {
        val (_, nsec) = freshNsec()
        var calls = 0
        assertEquals(emptyList<String>(), SecretKeyLeak.derivedPubkeys(corrupt(nsec)) { calls++; "x" })
        assertEquals(0, calls)
    }

    /** libhaven answers 00…00 for the zero key and n: that marks nobody. */
    @Test fun anAllZeroDerivedPubkeyIsSkipped() {
        val (_, nsec) = freshNsec()
        assertEquals(emptyList<String>(), SecretKeyLeak.derivedPubkeys(nsec) { "0".repeat(64) })
        PublicKeyRegistry.noteText(nsec) { "0".repeat(64) }
        assertTrue(PublicKeyRegistry.keys.value.isEmpty())
    }

    /** Your own accounts stay in your web even when their key is public, so your notes stay in Global. */
    @Test fun ownAccountsStayInsideWhenTheirKeyIsPublic() {
        val (mineHex, mine) = freshNsec()
        val (otherHex, other) = freshNsec()
        val me = TestSecp256k1.xOnly(mineHex)
        val them = TestSecp256k1.xOnly(otherHex)
        PublicKeyRegistry.noteText("$mine $other", TestSecp256k1::xOnly)
        val web = setOf(me, them, "friend")
        assertEquals(setOf(me, "friend"), PublicKeyRegistry.withoutPublic(web) { setOf(me.uppercase()) })
        assertEquals(setOf("friend"), PublicKeyRegistry.withoutPublic(web))
        // Nothing to remove: own accounts are not even read.
        var asked = false
        PublicKeyRegistry.withoutPublic(setOf("friend")) { asked = true; emptySet() }
        assertFalse(asked)
    }

    @Test fun theSignerGuardBlocksEveryPublishKindThatCarriesText() {
        val (_, nsec) = freshNsec()
        val profile = """{"name":"$nsec","about":"hi"}"""
        assertThrows(SecretKeyLeakException::class.java) { SecretKeyLeak.requireEventSafe(0, profile, emptyList()) }
        for (kind in listOf(1, 1111, 30023, 4, 14, 1068, 9802)) {
            val e = assertThrows(SecretKeyLeakException::class.java) { SecretKeyLeak.requireEventSafe(kind, "see $nsec", emptyList()) }
            assertEquals(SecretKeyLeak.MESSAGE, e.message)
        }
        // In a tag value (an article's title, summary or alt text).
        assertThrows(SecretKeyLeakException::class.java) {
            SecretKeyLeak.requireEventSafe(30023, "body", listOf(listOf("title", nsec)))
        }
        // The message never holds the key.
        val e = assertThrows(SecretKeyLeakException::class.java) { SecretKeyLeak.requireEventSafe(1, nsec, emptyList()) }
        assertFalse(e.message!!.contains("nsec1"))
    }

    @Test fun theSignerGuardLetsCleanEventsAndRepostsThrough() {
        val (_, nsec) = freshNsec()
        SecretKeyLeak.requireEventSafe(1, "hello", listOf(listOf("t", "nostr")))
        SecretKeyLeak.requireEventSafe(0, """{"name":"${corrupt(nsec)}"}""", emptyList())
        // A repost's content is someone else's event, already public.
        SecretKeyLeak.requireEventSafe(6, """{"content":"$nsec"}""", emptyList())
        SecretKeyLeak.requireEventSafe(16, """{"content":"$nsec"}""", emptyList())
    }

    @Test fun aProfileWithAKeyMarksThatKeysAccountPublicAndOutsideTheWeb() {
        val (hex, nsec) = freshNsec()
        val leaked = TestSecp256k1.xOnly(hex)
        val author = TestSecp256k1.xOnly(freshSecretHex())
        PublicKeyRegistry.noteText("""{"name":"$nsec"}""", TestSecp256k1::xOnly)

        assertTrue(PublicKeyRegistry.isPublic(leaked))
        assertTrue(PublicKeyRegistry.isPublic(leaked.uppercase()))
        // The profile that showed it is not the one marked.
        assertFalse(PublicKeyRegistry.isPublic(author))
        val web = setOf(leaked, author)
        assertEquals(setOf(author), PublicKeyRegistry.withoutPublic(web))
    }

    @Test fun profilesFromDiskAreReadToo() {
        val (hex, nsec) = freshNsec()
        PublicKeyRegistry.noteProfiles(listOf(FeedProfile(pubkey = "a", about = "my key $nsec")), TestSecp256k1::xOnly)
        assertTrue(PublicKeyRegistry.isPublic(TestSecp256k1.xOnly(hex)))
    }

    @Test fun aProfileWithoutAKeyMarksNobody() {
        val (_, nsec) = freshNsec()
        PublicKeyRegistry.noteText("""{"name":"${corrupt(nsec)}","about":"nsec1 prefix"}""", TestSecp256k1::xOnly)
        assertTrue(PublicKeyRegistry.keys.value.isEmpty())
        val web = setOf("a", "b")
        assertEquals(web, PublicKeyRegistry.withoutPublic(web))
    }
}

/** Plain secp256k1 for the test only: x-only public key of a secret key (BIP-340). */
internal object TestSecp256k1 {
    private val p = BigInteger("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F", 16)
    private val gx = BigInteger("79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798", 16)
    private val gy = BigInteger("483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8", 16)

    private fun add(a: Pair<BigInteger, BigInteger>?, b: Pair<BigInteger, BigInteger>?): Pair<BigInteger, BigInteger>? {
        if (a == null) return b
        if (b == null) return a
        if (a.first == b.first && (a.second + b.second).mod(p) == BigInteger.ZERO) return null
        val l = if (a == b) {
            BigInteger.valueOf(3).multiply(a.first.pow(2)).multiply(BigInteger.TWO.multiply(a.second).modInverse(p)).mod(p)
        } else {
            (b.second - a.second).multiply((b.first - a.first).modInverse(p)).mod(p)
        }
        val x = (l.pow(2) - a.first - b.first).mod(p)
        val y = (l.multiply(a.first - x) - a.second).mod(p)
        return x to y
    }

    fun xOnly(secretHex: String): String {
        var k = BigInteger(secretHex, 16)
        var r: Pair<BigInteger, BigInteger>? = null
        var q: Pair<BigInteger, BigInteger>? = gx to gy
        while (k > BigInteger.ZERO) {
            if (k.testBit(0)) r = add(r, q)
            q = add(q, q)
            k = k.shiftRight(1)
        }
        return r!!.first.toString(16).padStart(64, '0')
    }
}
