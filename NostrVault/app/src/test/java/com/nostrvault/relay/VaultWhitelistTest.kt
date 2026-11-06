package com.nostrvault.relay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files

/**
 * Logen's rule (2026-11-06 11:37Z): the vault's own keys are the device owner (always, even npub-only) plus accounts
 * with a key or a signer on this device. A watch-only account never gets vault access.
 */
class VaultWhitelistTest {
    private val owner = "npub1fsgzj6t7udv8zhf6zj32mkqhcjcpv52yph5qsdcl0qt94jgdckqs4yjc3w"
    private val watched = "npub13evkv42fprxqfpqdp966kn2cwpjrk9jflp08yelkkue20g977wpsv6pcap"
    private val withAmber = "npub1ks0t9yldwmqlr2k8jnm25gs92za45mp5rhwtkk0r0wlz9wg688zs99ny60"
    private val withBunker = "npub1qgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpq2yz0cn"
    private val dir = Files.createTempDirectory("vault-whitelist").toFile()

    private fun config(accounts: List<String> = listOf(watched, withAmber, withBunker)) = HavenConfig(
        ownerNpub = owner,
        accountNpubs = accounts,
        accountSigningModes = mapOf(watched to "local", withAmber to "amber", withBunker to "nip46"),
        accountBunkerConfigs = mapOf(withBunker to AccountBunkerConfig(bunkerURI = "bunker://x", signerPubkey = "a".repeat(64), relayURL = "wss://r")),
    )

    @Test
    fun `a watch-only account never gets vault access`() {
        // No key here (the key store isn't even open), no Amber, no bunker: not the vault's own.
        assertFalse(VaultWhitelist.canSignHere(config(), watched))
        assertFalse(watched in VaultWhitelist.npubs(config()))
        assertFalse(watched in RelayConfiguration.launchInputs(config(), dir) { throw IllegalStateException("no mesh") }.whitelist)
    }

    @Test
    fun `accounts with a signer on this device do, and the owner is never listed in the file`() {
        assertEquals(listOf(withAmber, withBunker), VaultWhitelist.npubs(config()))
        assertEquals(listOf(withAmber), VaultWhitelist.npubs(config()) { it == withAmber || it == owner })
    }

    @Test
    fun `the owner stays the vault's own with no key at all`() {
        val npubOnly = HavenConfig(ownerNpub = owner, signingMode = "browse")
        val inputs = RelayConfiguration.launchInputs(npubOnly, dir) { throw IllegalStateException("no mesh") }
        assertEquals(owner, inputs.env["OWNER_NPUB"])
        assertEquals(emptyList<String>(), inputs.whitelist)
    }

    @Test
    fun `the relay reads only this app's file, rebuilt from the rule, never a custom one`() {
        val custom = config().copy(whitelistedNpubsFile = "my_old_list.json")
        val env = RelayConfiguration.launchInputs(custom, dir) { throw IllegalStateException("no mesh") }.env
        assertEquals(RelayConfiguration.WHITELIST_FILE_NAME, env["WHITELISTED_NPUBS_FILE"])
    }

    @Test
    fun `a key or signer added or removed changes what the relay starts with, so it restarts`() {
        val before = RelayConfiguration.launchInputs(config(listOf(watched)), dir) { throw IllegalStateException("no mesh") }
        val after = RelayConfiguration.launchInputs(config(listOf(watched, withAmber)), dir) { throw IllegalStateException("no mesh") }
        assertNotEquals(before, after)
        assertTrue(withAmber in after.whitelist)
        // Amber taken away: back to watch-only, and out again.
        val dropped = config(listOf(watched, withAmber)).let { it.copy(accountSigningModes = it.accountSigningModes + (withAmber to "local")) }
        assertFalse(withAmber in RelayConfiguration.launchInputs(dropped, dir) { throw IllegalStateException("no mesh") }.whitelist)
    }
}
