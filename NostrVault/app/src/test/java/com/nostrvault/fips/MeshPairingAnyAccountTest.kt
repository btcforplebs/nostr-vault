package com.nostrvault.fips

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Two devices link when they share any signing account (Logen, 2026-11-06): the salted `ah` tags in A's code, the
 * optional `a` in the hello, and the session's matchAnyAccount. Same cases as iOS MeshPairingAnyAccountTests; the
 * shared fixtures (MeshPairingTest) still pin the old active-only ownerCheck.
 */
class MeshPairingAnyAccountTest {
    private val active = "npub1emme6lujwlzw6y2afr6teeuhgf7rt3n6yg40aagpyfuhuu06xf9q6z30yj"
    private val second = "npub1d3lkmjhu0mml5fy8tny0sqc55ggm9jsevx40pvurwlstvx9a7hpspnlmth"
    private val stranger = "npub1mfvctm9654sq6qqasdg6g27z0ms2yj9udt30w50eztsqjuv6sd3qzesed5"
    private val mesh = "npub1jc7rrss6ua9nxpqlwvcshs6rq8pdgjx6a6m63ey243nrjf7wqv3sy8aysl"
    private val secret = "MfL-vrRY_QiUhuVK2cwvQQ"
    private val other = "AAAAAAAAAAAAAAAAAAAAAA"

    private fun parsed(uri: String) = (MeshPairing.parse(uri, null) as MeshPairing.Parsed.Ok).payload

    @Test
    fun `the code carries salted tags, never npubs`() {
        val uri = MeshPairing.build(mesh, "Moto", DeviceRole.PHONE, active, MeshPairing.Code.Secret(secret), listOf(active, second, second, "npub1nope"))
        assertFalse(uri, second in uri)
        assertFalse(uri, MeshPairing.npubHex(second)!! in uri)
        val tag = MeshPairing.accountTag(second, secret)!!
        assertEquals(16, tag.length)
        assertTrue(uri, uri.endsWith("&ah=$tag"))
        val p = parsed(uri)
        assertEquals(active, p.owner)
        assertEquals("owner is in o, repeats and non-npubs are dropped", listOf(tag), p.accountTags)
        // The salt is the code's secret: another code tags the same account differently.
        assertNotEquals(tag, MeshPairing.accountTag(second, other))
        // No accounts: the code is exactly what it was.
        assertFalse("ah=" in MeshPairing.build(mesh, "Moto", DeviceRole.PHONE, active, MeshPairing.Code.Secret(secret)))
        // B's echo code never carries accounts; A reads them from the encrypted hello.
        assertFalse("ah=" in MeshPairing.build(mesh, "Moto", DeviceRole.PHONE, active, MeshPairing.Code.Echo(secret, secret), listOf(second)))
    }

    @Test
    fun `the tag is SHA-256 of nvpair-ah, the secret and the key, first 8 bytes`() {
        val s = MeshPairing.secretBytes(secret)!!
        val key = MeshPairing.npubHex(second)!!.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        val want = java.security.MessageDigest.getInstance("SHA-256").digest("nvpair-ah".toByteArray() + s + key)
            .take(8).joinToString("") { "%02x".format(it) }
        assertEquals(want, MeshPairing.accountTag(second, secret))
    }

    @Test
    fun `a bad tags field is ignored, not refused`() {
        val base = MeshPairing.build(mesh, "Moto", DeviceRole.PHONE, active, MeshPairing.Code.Secret(secret))
        val tag = MeshPairing.accountTag(second, secret)!!
        assertEquals(listOf(tag), parsed("$base&ah=$second,xyz,,$tag,$tag").accountTags)
        // An echo code's tags are not read.
        val echo = MeshPairing.build(mesh, "Moto", DeviceRole.PHONE, active, MeshPairing.Code.Echo(secret, secret))
        assertTrue(parsed("$echo&ah=$tag").accountTags.isEmpty())
    }

    @Test
    fun `the code's tags match only my accounts, and only with its own secret`() {
        val tag = MeshPairing.accountTag(second, secret)!!
        assertTrue(MeshPairing.sharesAccount(stranger, listOf(tag), secret, listOf(second)))
        assertTrue(MeshPairing.sharesAccount(active, emptyList(), secret, listOf(active)))
        assertFalse(MeshPairing.sharesAccount(stranger, listOf(tag), secret, listOf(active)))
        assertFalse(MeshPairing.sharesAccount(stranger, listOf(tag), other, listOf(second)))
    }

    /** Look-only accounts (npub only, no key or signer) don't count; the owner always does (Tron, PR 1809). */
    @Test
    fun `only signing accounts count`() {
        val canSign: (String) -> Boolean = { it == second }
        assertEquals(listOf(active, second), MeshPairing.signingAccounts(active, listOf(active, stranger, second), canSign))
        assertEquals(emptyList<String>(), MeshPairing.signingAccounts(active, emptyList(), canSign))
    }

    @Test
    fun `the hello carries the accounts`() {
        val h = MeshPairing.parseHello(MeshPairing.helloJson(secret, "Moto", DeviceRole.PHONE, active, 1, listOf(active, second)))!!
        assertEquals(listOf(second), h.accounts)
        assertEquals(emptyList<String>(), MeshPairing.parseHello(MeshPairing.helloJson(secret, "Moto", DeviceRole.PHONE, active, 1))!!.accounts)
        // A bad `a` is dropped, never a refusal.
        val bad = MeshPairing.helloJson(secret, "Moto", DeviceRole.PHONE, active, 1).dropLast(1) + ",\"a\":[\"x\",5,\"$second\"]}"
        assertEquals(listOf(second), MeshPairing.parseHello(bad)!!.accounts)
        assertEquals(emptyList<String>(), MeshPairing.parseHello(MeshPairing.helloJson(secret, "Moto", DeviceRole.PHONE, active, 1).dropLast(1) + ",\"a\":\"$second\"}")!!.accounts)
    }

    @Test
    fun `any shared account links`() {
        assertTrue(MeshPairing.sharesAccount(active, emptyList(), listOf(active)))
        // A Mac signed in as one account with a vault of another (Logen's case).
        assertTrue(MeshPairing.sharesAccount(stranger, listOf(second), listOf(second)))
        assertTrue(MeshPairing.sharesAccount(second, emptyList(), listOf(active, second)))
        assertFalse(MeshPairing.sharesAccount(stranger, emptyList(), listOf(active, second)))
        assertFalse(MeshPairing.sharesAccount("npub1nope", listOf("npub1nope"), listOf("npub1nope")))
    }

    private val ownMeshHex = "f29276ce125c563297e8f62e302c5d9e23d98f88ad7bd04f40f467c3a371730a"
    private val sender = "963c31c21ae74b33041f73310bc34301c2d448daeeb7a8e48aac663927ce0323"

    private fun session(any: Boolean, active: String? = this.active, accounts: List<String> = listOf(this.active, second)) =
        MeshPairingSession(secret, 1_793_800_000, ownMeshHex, active, accounts, matchAnyAccount = any)

    private fun hello(owner: String, accounts: List<String> = emptyList()) =
        MeshPairing.helloJson(secret, "Logen's iPhone", DeviceRole.PHONE, owner, 1_793_800_010, accounts)

    @Test
    fun `the session takes a hello that shares any account`() {
        assertTrue(session(true).receiveHello(sender, hello(second), 1_793_800_012) is MeshPairingSession.Outcome.Camera)
        assertTrue(session(true).receiveHello(sender, hello(stranger, listOf(second)), 1_793_800_012) is MeshPairingSession.Outcome.Camera)
        assertEquals(MeshPairingSession.Outcome.Refuse("otherOwner"), session(true).receiveHello(sender, hello(stranger), 1_793_800_012))
    }

    /** A look-only active account (left out of the accounts) doesn't link. */
    @Test
    fun `the session ignores a look-only active account`() {
        val s = session(true, active = stranger, accounts = listOf(active))
        assertEquals(MeshPairingSession.Outcome.Refuse("otherOwner"), s.receiveHello(sender, hello(stranger), 1_793_800_012))
    }

    /** Off (the shared contract): another account still asks to switch. */
    @Test
    fun `without the rule the session keeps the contract`() {
        assertEquals(MeshPairingSession.Outcome.Refuse("switchTo"), session(false).receiveHello(sender, hello(second), 1_793_800_012))
    }
}
