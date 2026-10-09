package com.nostrvault.data.local

import android.content.Context
import com.nostrvault.relay.HavenBridge
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * activeAccountHexPubkey must name the account the config names after every
 * write. It used to be set only at launch and on switch, so removing the
 * active account left it naming the removed one (Edit Profile then loaded one
 * account and signed as another).
 */
class ActiveAccountHexTest {

    private val filesDir: File = Files.createTempDirectory("config-store").toFile()
    private val context = mockk<Context> { every { filesDir } returns this@ActiveAccountHexTest.filesDir }

    private val owner = "npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m"
    private val second = "npub1gcxzte5zlkncx26j68ez60fzkvtkm9e0vrwdcvsjakxf9mu9qewqlfnj5z"
    private fun hex(npub: String) = HavenBridge.decodeNpub(npub)!!

    @After
    fun tearDown() {
        filesDir.deleteRecursively()
    }

    private fun store() = ConfigStore(context).apply {
        reload()
        update { it.copy(ownerNpub = owner, accountNpubs = listOf(second)) }
    }

    @Test
    fun `the owner is active by default`() {
        assertEquals(hex(owner), store().activeAccountHexPubkey.value)
    }

    @Test
    fun `switching follows the config`() = runBlocking {
        val store = store()
        store.update { it.copy(activeAccountNpub = second) }
        assertEquals(hex(second), store.activeAccountHexPubkey.value)
    }

    /** Logen, 2026-10-08: removing the account in use goes back to the main account. */
    @Test
    fun `removing the active account falls back to the owner`() {
        val store = store()
        store.update { it.copy(activeAccountNpub = second) }
        store.removeAccount(second)
        assertEquals(hex(owner), store.activeAccountHexPubkey.value)
    }

    /** Setup sets the value before the owner is saved; a write meanwhile keeps it. */
    @Test
    fun `before setup saves an owner, the value setup set is kept`() {
        val store = ConfigStore(context).apply { reload() }
        store.setActiveAccount(hex(second))
        store.update { it.copy(feedRelays = listOf("wss://a.example")) }
        assertEquals(hex(second), store.activeAccountHexPubkey.value)
    }

    /** Signing as the previous account would be worse than not signing. */
    @Test
    fun `an account that can't be decoded clears the value`() {
        val store = store()
        store.update { it.copy(activeAccountNpub = "npub1notarealkey") }
        assertEquals("", store.activeAccountHexPubkey.value)
    }

    @Test
    fun `which changes count as a switch`() {
        assertEquals(true, isAccountSwitch("aa", "bb"))
        assertEquals(true, isAccountSwitch("aa", ""))
        assertEquals(false, isAccountSwitch("", "aa"))
        assertEquals(false, isAccountSwitch("aa", "aa"))
    }

    @Test
    fun `accountSwitches reports a switch and not the starting account`() = runBlocking {
        val store = store()
        val seen = mutableListOf<String>()
        val job = launch(kotlinx.coroutines.Dispatchers.Unconfined) { store.accountSwitches.collect { seen += it } }
        store.update { it.copy(activeAccountNpub = second) }
        store.update { it.copy(activeAccountNpub = null) }
        job.cancel()
        assertEquals(listOf(hex(second), hex(owner)), seen)
    }
}

