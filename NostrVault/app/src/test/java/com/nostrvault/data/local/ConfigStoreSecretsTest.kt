package com.nostrvault.data.local

import android.content.Context
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * Upgrading an install whose nostrvault_config.json holds the wallet
 * connection and the NIP-46 signer links as plaintext (ConfigSecrets). The
 * fixture is a config file in that shape.
 */
class ConfigStoreSecretsTest {

    private val filesDir: File = Files.createTempDirectory("config-secrets").toFile()
    private val context = mockk<Context> { every { filesDir } returns this@ConfigStoreSecretsTest.filesDir }
    private val configFile = File(filesDir, "nostrvault_config.json")

    private val owner = "npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m"
    private val second = "npub1fixturesecond"

    private val fixture: String =
        javaClass.classLoader!!.getResource("config-secrets/nostrvault_config-before-keystore.json")!!.readText()

    /** Every secret in the fixture. None may be readable in the file after the migration. */
    private val fixtureSecrets = listOf(
        "nostr+walletconnect://fixture-wallet-pubkey?relay=wss://relay.example.invalid&secret=fixture-nwc-secret",
        "bunker://fixture-signer-pubkey?relay=wss://signer.example.invalid&secret=fixture-connect-secret",
        "bunker://fixture-second-signer?relay=wss://signer.example.invalid&secret=fixture-second-secret",
        "fixture-nwc-secret", "fixture-connect-secret", "fixture-second-secret",
        "fixture-owner-client-secret", "fixture-second-client-secret",
    )

    /** An in-memory credential store; [open] false is one that could not be opened (reads nothing, writes fail). */
    private class FakeSecrets(var open: Boolean = true) : ConfigStore.SecretVault {
        val items = mutableMapOf<String, String>()
        val deletes = mutableListOf<String>()
        override fun read(account: String) = if (open) items[account] else null
        override fun write(account: String, value: String): Boolean {
            if (open) items[account] = value
            return open
        }
        override fun delete(account: String): Boolean {
            deletes += account
            if (open) items.remove(account)
            return open
        }
    }

    private class NoKeys : ConfigStore.KeyVault {
        override fun read(hexPubkey: String): String? = null
        override fun write(hexKey: String, hexPubkey: String) = true
        override fun forgetOwner(hexPubkey: String?, npub: String) {}
    }

    private val secrets = FakeSecrets()

    @After
    fun tearDown() {
        filesDir.deleteRecursively()
    }

    private fun store() = ConfigStore(context).apply {
        keyVault = NoKeys()
        secretVault = secrets
        clearPrefs = {}
        wipeOutsideFiles = {}
        publicKeyOf = { null }
        reload()
    }

    private fun assertNoSecrets(text: String, where: String) {
        for (s in fixtureSecrets) assertFalse("$where still holds $s", text.contains(s))
    }

    @Test
    fun `an existing install migrates on first open and loses nothing`() = runBlocking {
        configFile.writeText(fixture)
        val before = Json { ignoreUnknownKeys = true }.decodeFromString<com.nostrvault.relay.HavenConfig>(fixture)

        val store = store()
        assertEquals("the running app keeps every value", before.nwcURI, store.config.value.nwcURI)
        store.save()

        assertNoSecrets(configFile.readText(), "nostrvault_config.json")
        val disk = configFile.readText()
        assertTrue("the signer's pubkey stays: it tells a signing account", disk.contains("fixture-signer-pubkey"))
        assertTrue(disk.contains("ncryptsec1fixtureencryptedkey"))
        assertEquals(7, secrets.items.size)

        // Next open: the file is blank there; the store fills it all back in.
        val reopened = store().config.value
        assertEquals(before.nwcURI, reopened.nwcURI)
        assertEquals(before.accountBunkerConfigs, reopened.accountBunkerConfigs)
        assertEquals("signing still goes to the signer", "nip46", reopened.activeSigningMode())
        assertTrue(reopened.bunkerConfig(second) != null)
    }

    @Test
    fun `a copy set aside unreadable is scrubbed and still parses`() = runBlocking {
        configFile.writeText(fixture)
        val aside = File(filesDir, "nostrvault_config.json.unreadable-1700000000")
        aside.writeText(fixture)
        val unrelated = File(filesDir, "drafts.json")
        unrelated.writeText("fixture-nwc-secret")

        store().save()

        val text = aside.readText()
        assertNoSecrets(text, aside.name)
        val parsed = Json.parseToJsonElement(text).jsonObject
        assertEquals("\"ncryptsec1fixtureencryptedkey\"", parsed["ownerNcryptsec"].toString())
        assertEquals("only the config's copies", "fixture-nwc-secret", unrelated.readText())
    }

    @Test
    fun `a short secret is scrubbed only where it is the whole value`() {
        val text = """{"ownerNcryptsec":"ncryptsec1q1q1","accountBunkerConfigs":{"a":{"secret":"1"}},"relayPort":3311}"""
        assertEquals(
            """{"ownerNcryptsec":"ncryptsec1q1q1","accountBunkerConfigs":{"a":{"secret":""}},"relayPort":3311}""",
            ConfigSecrets.scrub(text, listOf("1")),
        )
    }

    @Test
    fun `a store that cannot be written keeps the secrets in the file until it can`() = runBlocking {
        configFile.writeText(fixture)
        secrets.open = false
        store().save()
        assertTrue(configFile.readText().contains("fixture-nwc-secret"))

        secrets.open = true
        val store = store()
        store.save()
        assertNoSecrets(configFile.readText(), "nostrvault_config.json")
        assertEquals(7, secrets.items.size)
    }

    @Test
    fun `a store that cannot be read is never emptied`() = runBlocking {
        configFile.writeText(fixture)
        store().save()
        assertEquals(7, secrets.items.size)

        secrets.open = false
        val closed = store()
        assertNull("nothing to fill in from a closed store", closed.config.value.nwcURI)
        closed.save()
        closed.updateAsync { it.copy(defaultZapAmount = 500) }
        assertEquals("no delete is even tried", emptyList<String>(), secrets.deletes)

        secrets.open = true
        val back = store().config.value
        assertEquals(500, back.defaultZapAmount)
        assertTrue(back.nwcURI!!.contains("fixture-nwc-secret"))
        assertEquals("fixture-second-client-secret", back.accountBunkerConfigs[second]?.clientSecretKey)
    }

    @Test
    fun `disconnecting the wallet and removing a signer delete them from the store`() = runBlocking {
        configFile.writeText(fixture)
        val store = store()
        store.save()
        store.updateAsync { it.copy(nwcURI = null, accountBunkerConfigs = it.accountBunkerConfigs - second) }

        assertEquals(
            setOf(ConfigSecrets.bunkerURI(owner), ConfigSecrets.bunkerSecret(owner), ConfigSecrets.clientSecretKey(owner)),
            secrets.items.keys,
        )
        assertNull(store().config.value.nwcURI)
    }

    @Test
    fun `a value in the file beats the store`() {
        val cfg = com.nostrvault.relay.HavenConfig(nwcURI = "nostr+walletconnect://in-the-file")
        val attached = ConfigSecrets.attach(cfg) { if (it == ConfigSecrets.NWC_URI) "nostr+walletconnect://stale" else null }
        assertEquals("nostr+walletconnect://in-the-file", attached.nwcURI)
    }
}
