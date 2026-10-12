package com.nostrvault.data.local

import android.content.Context
import io.mockk.every
import io.mockk.mockk
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * A block on a second account starts from that account's own list. It used to
 * start from the owner's legacy list, copying the owner's blocks into the
 * second account's list, which was then published as its mute list.
 */
class ConfigStoreBlockTest {

    private val filesDir: File = Files.createTempDirectory("config-store").toFile()
    private val context = mockk<Context> { every { filesDir } returns this@ConfigStoreBlockTest.filesDir }

    private val owner = "npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m"
    private val second = "npub1gcxzte5zlkncx26j68ez60fzkvtkm9e0vrwdcvsjakxf9mu9qewqlfnj5z"
    private val alice = "npub1alice"
    private val bob = "npub1bob"

    @After
    fun tearDown() {
        filesDir.deleteRecursively()
    }

    private fun store() = ConfigStore(context).apply {
        reload()
        update { it.copy(ownerNpub = owner, accountNpubs = listOf(second), blockedNpubs = listOf(alice)) }
    }

    @Test
    fun `a second account's block does not copy the owner's legacy blocks`() {
        val store = store()
        store.update { it.copy(activeAccountNpub = second) }
        store.blockProfile(bob)
        assertEquals(listOf(bob), store.config.value.blockedForActiveAccount())
        assertEquals(listOf(alice), store.config.value.blockedFor(owner))
    }

    @Test
    fun `the owner's block keeps the legacy blocks`() {
        val store = store()
        store.blockProfile(bob)
        assertEquals(listOf(alice, bob), store.config.value.blockedForActiveAccount())
    }
}
