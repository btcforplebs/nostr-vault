package com.nostrvault.data.local

import android.content.Context
import com.nostrvault.relay.HavenBridge
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * D1: a config file that can't be read is set aside, not overwritten, and
 * saves land whole and newest-last. K2: the owner's secret key is kept in the
 * credential store, not in nostrvault_config.json.
 */
class ConfigStoreSaveTest {

    private val filesDir: File = Files.createTempDirectory("config-save").toFile()
    private val context = mockk<Context> { every { filesDir } returns this@ConfigStoreSaveTest.filesDir }
    private val configFile = File(filesDir, "nostrvault_config.json")

    private val owner = "npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m"
    private val ownerHex = HavenBridge.decodeNpub(owner)!!
    private val secret = "5e".repeat(32)

    /** An in-memory credential store; [works] false is a store that can't be opened. */
    private class FakeVault(var works: Boolean = true) : ConfigStore.KeyVault {
        val keys = mutableMapOf<String, String>()
        override fun read(hexPubkey: String) = if (works) keys[hexPubkey] else null
        override fun write(hexKey: String, hexPubkey: String): Boolean {
            if (works) keys[hexPubkey] = hexKey
            return works
        }
        val forgotten = mutableListOf<Pair<String?, String>>()
        override fun forgetOwner(hexPubkey: String?, npub: String) {
            forgotten += hexPubkey to npub
            hexPubkey?.let { keys.remove(it) }
        }
    }

    private val vault = FakeVault()

    @After
    fun tearDown() {
        filesDir.deleteRecursively()
    }

    private fun store() = ConfigStore(context).apply {
        keyVault = vault
        publicKeyOf = { if (it == secret) ownerHex else null }
        reload()
    }

    private fun setAside() = filesDir.listFiles()!!.filter { it.name.startsWith("nostrvault_config.json.unreadable-") }

    @Test
    fun `an unreadable config is set aside, not lost`() {
        val damaged = """{"ownerNpub":"$owner","hasCompletedSetup":true,"accountNpubs":["""
        configFile.writeText(damaged)

        val store = store()
        assertFalse(store.config.value.hasCompletedSetup)
        runBlocking { store.save() }

        val aside = filesDir.listFiles()!!.filter { it.name.startsWith("nostrvault_config.json.unreadable-") }
        assertEquals(1, aside.size)
        assertEquals(damaged, aside[0].readText())
    }

    @Test
    fun `a save leaves no temp file and the last save is the newest config`() = runBlocking {
        val store = store()
        (1..50).map { n ->
            async(kotlinx.coroutines.Dispatchers.IO) {
                store.updateAsync { it.copy(relayPort = 4000 + n) }
            }
        }.awaitAll()
        val newest = store.config.value.relayPort
        assertEquals(newest, ConfigStore(context).apply { keyVault = vault; reload() }.config.value.relayPort)
        assertFalse(File(filesDir, "nostrvault_config.json.tmp").exists())
    }

    @Test
    fun `a new owner key goes to the credential store, not the file`() = runBlocking {
        val store = store()
        store.updateAsync { it.copy(ownerNpub = owner, ownerHexKey = secret) }

        assertFalse(configFile.readText().contains(secret))
        assertEquals(secret, vault.keys[ownerHex])
        assertEquals(secret, store().config.value.ownerHexKey)
    }

    @Test
    fun `a key an older build saved in the file moves to the credential store`() = runBlocking {
        configFile.writeText("""{"ownerNpub":"$owner","hasCompletedSetup":true,"ownerHexKey":"$secret"}""")

        val store = store()
        assertEquals(secret, store.config.value.ownerHexKey)
        store.save()

        assertFalse(configFile.readText().contains(secret))
        assertEquals(secret, vault.keys[ownerHex])
        val reopened = store()
        assertEquals(secret, reopened.config.value.ownerHexKey)
        assertTrue(reopened.config.value.hasCompletedSetup)
    }

    @Test
    fun `a key the credential store can't take stays in the file`() = runBlocking {
        vault.works = false
        val store = store()
        store.updateAsync { it.copy(ownerNpub = owner, ownerHexKey = secret) }

        assertTrue(configFile.readText().contains(secret))
        assertEquals(secret, store().config.value.ownerHexKey)

        // Once the store works again, the next save moves it there.
        vault.works = true
        store().save()
        assertFalse(configFile.readText().contains(secret))
        assertEquals(secret, vault.keys[ownerHex])
    }

    @Test
    fun `a different key already stored for the owner is not overwritten`() = runBlocking {
        vault.keys[ownerHex] = "7a".repeat(32)
        val store = store()
        store.updateAsync { it.copy(ownerNpub = owner, ownerHexKey = secret) }
        assertEquals("7a".repeat(32), vault.keys[ownerHex])
        assertTrue(configFile.readText().contains(secret))
    }

    @Test
    fun `removing the owner key keeps it out of the file`() = runBlocking {
        val store = store()
        store.updateAsync { it.copy(ownerNpub = owner, ownerHexKey = secret) }
        store.updateAsync { it.copy(ownerHexKey = null) }
        assertNull(Regex("\"ownerHexKey\"").find(configFile.readText()))
    }

    @Test
    fun `a truncated config's owner key goes to the credential store, not back into plain text`() = runBlocking {
        configFile.writeText("""{"hasCompletedSetup":true,"ownerHexKey":"$secret","accountNpubs":[""")

        val store = store()
        store.save()

        assertEquals(secret, vault.keys[ownerHex])
        assertFalse(configFile.readText().contains(secret))
        assertEquals(1, setAside().size)
        assertFalse(setAside()[0].readText().contains(secret))
    }

    @Test
    fun `a config that parses but won't decode does not write its key back`() = runBlocking {
        configFile.writeText("""{"ownerNpub":"$owner","ownerHexKey":"$secret","relayPort":"not a number"}""")

        val store = store()
        store.save()

        assertEquals(secret, vault.keys[ownerHex])
        assertFalse(configFile.readText().contains(secret))
        assertFalse(setAside()[0].readText().contains(secret))
    }

    @Test
    fun `an unreadable config's key the store can't take stays in the set-aside copy`() = runBlocking {
        vault.works = false
        configFile.writeText("""{"ownerNpub":"$owner","ownerHexKey":"$secret",""")
        store().save()
        assertTrue(setAside()[0].readText().contains(secret))
    }

    @Test
    fun `factory reset forgets the owner key and the set-aside copies`() = runBlocking {
        configFile.writeText("{broken")
        val store = store()
        store.updateAsync { it.copy(ownerNpub = owner, ownerHexKey = secret) }
        assertEquals(1, setAside().size)

        store.resetApp()

        assertEquals(listOf<Pair<String?, String>>(ownerHex to owner), vault.forgotten)
        assertNull(vault.keys[ownerHex])
        assertTrue(setAside().isEmpty())
        assertFalse(configFile.exists())
        assertNull(store.config.value.ownerHexKey)
    }
}
