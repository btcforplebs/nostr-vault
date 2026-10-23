package com.nostrvault.fips

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.local.CredentialStore
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkObject
import io.mockk.unmockkAll
import io.mockk.verify
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Before
import org.junit.Test

/**
 * The mesh address is the npub of a key this device keeps. A read of that key that fails (a value that will
 * not decrypt, a store that would not open) must not be taken for "no key yet": minting one then changes the
 * address every peer saved. Mac/iOS fixed the same in #1122.
 */
class FipsMeshIdentityReadTest {
    @Before fun setUp() {
        mockkObject(CredentialStore)
        mockkObject(FipsBridge)
        every { FipsBridge.isAvailable } returns true
        every { FipsBridge.generateNsec() } returns "nsec1minted"
    }

    @After fun tearDown() = unmockkAll()

    @Test fun `an unreadable mesh key stops the start instead of minting a new address`() = runTest {
        every { CredentialStore.readMeshNsec() } throws javax.crypto.AEADBadTagException("bad tag")
        val manager = FipsMeshManager(CredentialStore, mockk<ConfigStore>(relaxed = true), CoroutineScope(UnconfinedTestDispatcher()))
        assertFalse(manager.start(persist = false))
        assertEquals("Could not read the mesh identity.", manager.lastError.value)
        verify(exactly = 0) { FipsBridge.generateNsec() }
        verify(exactly = 0) { CredentialStore.storeMeshNsec(any()) }
    }

    @Test fun `no saved mesh key is minted and saved`() = runTest {
        every { CredentialStore.readMeshNsec() } returns null
        every { CredentialStore.storeMeshNsec(any()) } returns false
        val manager = FipsMeshManager(CredentialStore, mockk<ConfigStore>(relaxed = true), CoroutineScope(UnconfinedTestDispatcher()))
        // The save is refused here, so the start stops before the engine; what matters is that a key was minted.
        assertFalse(manager.start(persist = false))
        verify(exactly = 1) { FipsBridge.generateNsec() }
        verify(exactly = 1) { CredentialStore.storeMeshNsec("nsec1minted") }
    }
}
