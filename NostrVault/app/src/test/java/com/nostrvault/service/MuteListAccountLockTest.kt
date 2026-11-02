package com.nostrvault.service

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.PostingAccount
import com.nostrvault.relay.HavenConfig
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.security.SecureRandom

/**
 * A block or unblock signs the mute list (kind 10000) of the account whose list was fetched, and only that one
 * (list-wipe audit 2026-11-02). The lookup before signing can take 6 s; switching account in that time used to sign
 * account A's list with account B's key, and publish it as B's.
 */
class MuteListAccountLockTest {

    /** Random hex, so no test key is a real account. */
    private fun throwaway(): String = ByteArray(32).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it) }

    private val alice = throwaway()
    private val bob = throwaway()
    private val carol = throwaway()
    private val dave = throwaway()
    private val npubs = mapOf("npub1alice" to alice, "npub1bob" to bob, "npub1dave" to dave)
    private val lockA = PostingAccount.Lock(npub = "npub1alice", hex = alice)
    private val lockB = PostingAccount.Lock(npub = "npub1bob", hex = bob)
    private val own = listOf("wss://own.example")

    private lateinit var nostr: NostrService
    /** The active account right now; the lookup can switch it. */
    @Volatile private var active = lockA
    /** Who to switch to while the list is being fetched; null keeps the account. */
    @Volatile private var switchDuringLookup: PostingAccount.Lock? = null
    /** Whose key the signer uses; null is the active account's, as the real signer does. */
    @Volatile private var signerKey: String? = null
    private var lockedTo: PostingAccount.Lock? = null

    @Before
    fun setUp() {
        nostr = mockk(relaxed = true)
        val store = mockk<ConfigStore>(relaxed = true) {
            every { config } returns MutableStateFlow(HavenConfig(ownerNpub = "npub1alice", accountNpubs = listOf("npub1bob")))
        }
        every { nostr.configStore } returns store
        every { nostr.ownerHexPubkey } returns alice
        every { nostr.activeHexPubkey } answers { active.hex }
        every { nostr.lockPostingAccount() } answers { active }
        every { nostr.npubToHex(any()) } answers { npubs[firstArg()] }
        every { nostr.relayLists } returns MutableStateFlow(emptyMap())
        coEvery { nostr.ownListRelays(alice) } returns own
        coEvery { nostr.lookupNewestReplaceable(10000, alice, any(), any(), any()) } answers {
            switchDuringLookup?.let { active = it }
            NostrService.ReplaceableLookup(
                NostrEvent("e".repeat(64), alice, 100, 10000, listOf(listOf("p", carol)), "", ""),
                // Its own relay and an indexer answered: a single answer is never enough.
                asked = 2, answered = 2, answeredBy = own.toSet() + "wss://purplepag.es", from = own.toSet(),
            )
        }
        // As signEventAsyncImpl: with lockedTo, refuses unless that account is still the active one.
        coEvery { nostr.signEventAsync(10000, any(), any(), any(), any(), any(), any(), any()) } answers {
            lockedTo = arg(5)
            lockedTo?.let { if (it != active) throw PostingAccount.AccountChangedException() }
            NostrEvent("1".repeat(64), signerKey ?: active.hex, 200, 10000, arg(2), arg(1), "")
        }
    }

    private fun block() = runBlocking {
        nostr.publishMuteListChangeImpl("npub1alice", add = listOf("npub1dave"), remove = emptyList(), localBlocks = listOf("npub1dave"))
    }

    @Test
    fun `a block with no switch publishes on the fetched list`() {
        assertNull(block())
        assertEquals(lockA, lockedTo)
        coVerify(exactly = 1) {
            nostr.postEvent(match { it.pubkey == alice && it.tags == listOf(listOf("p", carol), listOf("p", dave)) }, any())
        }
    }

    @Test
    fun `a switch during the fetch publishes nothing`() {
        switchDuringLookup = lockB
        val why = block()
        assertTrue(why, why!!.contains("account changed"))
        // Locked to the account active when the block started, not the one switched to.
        assertEquals(lockA, lockedTo)
        coVerify(exactly = 0) { nostr.postEvent(any(), any()) }
    }

    @Test
    fun `a list signed with another key is never published`() {
        signerKey = bob
        val why = block()
        assertTrue(why, why!!.contains("account changed"))
        coVerify(exactly = 0) { nostr.postEvent(any(), any()) }
    }

    @Test
    fun `a switch before the fetch fetches and signs nothing`() {
        active = lockB
        val why = block()
        assertTrue(why, why!!.contains("account changed"))
        coVerify(exactly = 0) { nostr.lookupNewestReplaceable(10000, any(), any(), any(), any()) }
        coVerify(exactly = 0) { nostr.signEventAsync(10000, any(), any(), any(), any(), any(), any(), any()) }
        coVerify(exactly = 0) { nostr.postEvent(any(), any()) }
    }
}
