package com.nostrvault.service

import com.nostrvault.relay.AccountBunkerConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.URI
import java.net.URLDecoder

/**
 * The nostrconnect:// request a signer app reads, and the bunker:// link a
 * finished pairing is stored as (iOS NIP46Service.makeNostrConnectRequest /
 * bunkerURI(signerPubkey:relays:)).
 */
class NostrConnectUriTest {
    private val clientPk = "c".repeat(64)
    private val signerPk = "5".repeat(64)
    private val secret = "0123456789abcdef0123456789abcdef"
    private val relays = listOf("wss://relay.powr.build", "wss://relay.damus.io")

    private fun query(uri: String): List<Pair<String, String>> =
        URI(uri).rawQuery.split("&").map {
            val (k, v) = it.split("=", limit = 2)
            k to URLDecoder.decode(v, "UTF-8")
        }

    @Test
    fun nostrConnectUriCarriesClientKeyRelaysSecretAndPerms() {
        val uri = NIP46Service.nostrConnectUri(clientPk, secret, relays)
        assertTrue(uri.startsWith("nostrconnect://$clientPk?"))
        assertEquals(clientPk, URI(uri).host)
        val q = query(uri)
        assertEquals(relays, q.filter { it.first == "relay" }.map { it.second })
        assertEquals(listOf(secret), q.filter { it.first == "secret" }.map { it.second })
        val perms = q.single { it.first == "perms" }.second.split(",")
        assertTrue(perms.containsAll(listOf("sign_event", "nip04_encrypt", "nip44_encrypt", "nip44_decrypt")))
        assertEquals("Nostr Vault", q.single { it.first == "name" }.second)
    }

    /** A "+" or bare space in a value is read back as a space by some decoders. */
    @Test
    fun nostrConnectUriHasNoPlusOrSpace() {
        val uri = NIP46Service.nostrConnectUri(clientPk, secret, relays)
        assertFalse(uri.contains('+'))
        assertFalse(uri.contains(' '))
        assertTrue(uri.contains("name=Nostr%20Vault"))
    }

    @Test
    fun bunkerUriHasSignerHostAndRelaysAndNoSecret() {
        val uri = NIP46Service.bunkerUri(signerPk, relays)
        assertEquals("bunker://$signerPk?relay=wss://relay.powr.build&relay=wss://relay.damus.io", uri)
        assertFalse(uri.contains("secret"))
    }

    /** The stored link files its Go session under the remote signer's key. */
    @Test
    fun storedPairingSessionKeyIsTheSignerNotTheAccount() {
        val cfg = AccountBunkerConfig(
            bunkerURI = NIP46Service.bunkerUri(signerPk, relays),
            signerPubkey = "a".repeat(64),
            clientSecretKey = "1".repeat(64),
            clientPubkey = clientPk,
        )
        assertEquals(signerPk, NIP46Service.signerKey(cfg))
    }
}
