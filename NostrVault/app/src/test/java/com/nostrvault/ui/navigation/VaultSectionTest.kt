package com.nostrvault.ui.navigation

import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** The Vault tab's half across Android killing the app (the photo picker case). */
class VaultSectionTest {
    @Before fun freshProcess() = VaultSection.resetForTest()
    @After fun cleanUp() = VaultSection.resetForTest()

    @Test fun `a fresh launch opens on the relay half`() {
        assertFalse(VaultSection.showsMedia.value)
    }

    @Test fun `a restored process comes back on the half it was on`() {
        VaultSection.restore(media = true)
        assertTrue(VaultSection.showsMedia.value)
    }

    @Test fun `a route that arrived before the restore wins`() {
        // A notification tap relaunched the app: it asked for the relay half
        // before the tab restored its saved Media half.
        VaultSection.show(media = false)
        VaultSection.restore(media = true)
        assertFalse(VaultSection.showsMedia.value)
    }

    @Test fun `a route that arrives after the restore wins`() {
        VaultSection.restore(media = true)
        VaultSection.show(media = false)
        assertFalse(VaultSection.showsMedia.value)
    }

    @Test fun `only the first restore counts`() {
        VaultSection.restore(media = true)
        VaultSection.restore(media = false)
        assertTrue(VaultSection.showsMedia.value)
    }
}
