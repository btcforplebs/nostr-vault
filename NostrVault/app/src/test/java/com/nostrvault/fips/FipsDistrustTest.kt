package com.nostrvault.fips

import io.mockk.every
import io.mockk.mockkObject
import io.mockk.unmockkObject
import io.mockk.verify
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

class FipsDistrustTest {
    private val bad = "npub1" + "a".repeat(58)
    private val good = "npub1" + "c".repeat(58)
    private val base = "http://127.0.0.1:40001"

    @Before
    fun setUp() {
        mockkObject(FipsBridge)
        every { FipsBridge.ingress(any()) } returns FipsIngress(url = base)
    }

    @After
    fun tearDown() = unmockkObject(FipsBridge)

    @Test
    fun distrustedVaultIsNotDialledAgain() {
        // Control: before distrust the same vault is reachable.
        assertEquals(base, FipsMediaRouter.ingressBase(bad))
        FipsMediaRouter.distrust(bad)
        assertNull(FipsMediaRouter.ingressBase(bad))
        verify(exactly = 1) { FipsBridge.ingress(bad) }
        // Only the vault that misbehaved is cut off.
        assertEquals(base, FipsMediaRouter.ingressBase(good))
    }
}
