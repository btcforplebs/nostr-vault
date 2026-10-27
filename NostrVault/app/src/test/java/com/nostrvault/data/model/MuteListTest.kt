package com.nostrvault.data.model

import com.nostrvault.relay.HavenConfig
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A kind 10000 read whole: the public "p" tags and the encrypted private
 * part. The test decrypter stands in for NIP-44 / NIP-04 (native code).
 */
class MuteListTest {
    private val pub1 = "a".repeat(64)
    private val pub2 = "b".repeat(64)
    private val priv1 = "c".repeat(64)
    private val priv2 = "d".repeat(64)

    private val tags = listOf(listOf("p", pub1), listOf("word", "spam"), listOf("p", pub2.uppercase()), listOf("p", "not-a-key"), listOf("t", "nsfw"))
    private val privatePlain = """[["p","$priv1"],["word","x"],["p","$priv2","wss://r"],["e","${"e".repeat(64)}"]]"""

    /** Decrypts anything starting "enc:" by dropping the prefix; records which scheme was asked for. */
    private class Fake { var nip04: Boolean? = null }
    private fun decrypter(fake: Fake): suspend (String, Boolean) -> String? = { c, nip04 ->
        fake.nip04 = nip04
        if (c.startsWith("enc:")) c.removePrefix("enc:").substringBefore("?iv=") else null
    }

    @Test
    fun publicAndPrivateEntries() = runBlocking {
        val fake = Fake()
        val e = MuteList.entries(tags, "enc:$privatePlain", decrypter(fake))
        assertEquals(listOf(pub1, pub2), e.public)
        assertEquals(listOf(priv1, priv2), e.private)
        assertEquals(false, fake.nip04)
    }

    @Test
    fun nip04ContentIsOpenedAsNip04() = runBlocking {
        val fake = Fake()
        val e = MuteList.entries(tags, "enc:$privatePlain?iv=abc", decrypter(fake))
        assertEquals(true, fake.nip04)
        assertEquals(listOf(priv1, priv2), e.private)
    }

    @Test
    fun noContentMeansNoPrivateEntries() = runBlocking {
        val e = MuteList.entries(tags, "", decrypter(Fake()))
        assertEquals(listOf(pub1, pub2), e.public)
        assertEquals(emptyList<String>(), e.private)
    }

    /** A read-only account can't open it: unknown, not empty, and the public part still applies. */
    @Test
    fun unopenablePrivatePartIsUnknown() = runBlocking {
        val e = MuteList.entries(tags, "sealed", decrypter(Fake()))
        assertEquals(listOf(pub1, pub2), e.public)
        assertNull(e.private)
        assertNull(MuteList.entries(tags, "enc:not json", decrypter(Fake())).private)
        assertNull(MuteList.entries(tags, "x") { _, _ -> throw IllegalStateException("signer gone") }.private)
    }

    private val owner = "npub1owner"
    private val alice = "npub1alice"
    private val secret = "npub1secret"
    private val cfg = HavenConfig(
        ownerNpub = owner,
        blockedNpubsPerAccount = mapOf(owner to listOf(alice)),
        privateBlockedNpubsPerAccount = mapOf(owner to listOf(secret)),
    )

    @Test
    fun privateEntriesBlockButAreNotPublic() {
        assertEquals(listOf(alice, secret), cfg.blockedForActiveAccount())
        assertEquals(listOf(alice), cfg.publicBlockedFor(owner))
        assertTrue(secret in cfg.allBlockedNpubsAcrossAccounts())
    }

    /** Unblocking someone public must not copy the private entries into the public list. */
    @Test
    fun unblockKeepsPrivateEntriesOutOfThePublicList() {
        val after = BlockedPeople.unblock(cfg, alice)
        assertEquals(emptyList<String>(), after.publicBlockedFor(owner))
        assertEquals(listOf(secret), after.blockedForActiveAccount())
    }

    @Test
    fun unblockingAPrivateEntryUnhidesIt() {
        val after = BlockedPeople.unblock(cfg, secret)
        assertFalse(secret in after.blockedForActiveAccount())
        assertEquals(listOf(alice), after.publicBlockedFor(owner))
    }
}
