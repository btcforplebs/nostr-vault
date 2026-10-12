package com.nostrvault.data.local

import android.content.Context
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * Unblock from a profile or the globe goes through [ConfigStore.unblockProfile],
 * the same as the Blocked page. It used to leave the npub in the legacy list,
 * which the relay's blacklist unions in, so the relay kept blocking that person.
 */
class ConfigStoreUnblockTest {

    private val filesDir: File = Files.createTempDirectory("config-store").toFile()
    private val context = mockk<Context> { every { filesDir } returns this@ConfigStoreUnblockTest.filesDir }

    private val owner = "npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m"
    private val alice = "npub1gcxzte5zlkncx26j68ez60fzkvtkm9e0vrwdcvsjakxf9mu9qewqlfnj5z"

    @After
    fun tearDown() {
        filesDir.deleteRecursively()
    }

    @Test
    fun `unblocking the last legacy block clears it for the relay after a relaunch`() = runBlocking {
        val store = ConfigStore(context).apply {
            reload()
            update { it.copy(ownerNpub = owner, blockedNpubs = listOf(alice)) }
        }
        assertEquals(listOf(alice), store.config.value.allBlockedNpubsAcrossAccounts())

        store.unblockProfile(alice)
        store.save()

        val relaunched = ConfigStore(context).apply { reload() }
        assertEquals(emptyList<String>(), relaunched.config.value.blockedForActiveAccount())
        assertEquals(emptyList<String>(), relaunched.config.value.allBlockedNpubsAcrossAccounts())
    }
}
