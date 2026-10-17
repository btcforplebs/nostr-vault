package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The saved-wallet slot must stay readable by Wisp and read Wisp's
 * (barrydeen/wisp `Nip78.kt`, `createNwcBackupEvent` / `decryptNwcBackup`).
 * Same cases as iOS NWCBackupTests.
 */
class NwcBackupTest {
    private val uri = "nostr+walletconnect://b889ff5b1513b641e2a139f661a661364979c5beee91842f8f0ef42ab558e9d4?relay=wss%3A%2F%2Frelay.example&secret=71a8c14c1407c113601079c4302dab36460f0ccd0ad506f1f2dc73b5100e4f3c"

    @Test
    fun `slot is Wisp's`() {
        assertEquals(30078, NwcBackup.KIND)
        assertEquals("nwc-wallet-backup", NwcBackup.D_TAG)
        assertTrue(listOf("d", "nwc-wallet-backup") in NwcBackup.TAGS)
        assertTrue(listOf("encryption", "nip44") in NwcBackup.TAGS)
    }

    @Test
    fun `reads Wisp's own event`() {
        val wispTags = listOf(listOf("d", "nwc-wallet-backup"), listOf("client", "Wisp"), listOf("encryption", "nip44"))
        assertTrue(NwcBackup.isBackup(30078, wispTags))
        assertFalse(NwcBackup.isCleared("AgV0ciphertext", wispTags))
    }

    @Test
    fun `other app data is not the slot`() {
        assertFalse(NwcBackup.isBackup(30078, listOf(listOf("d", "spark-wallet-backup:0123456789abcdef"))))
        assertFalse(NwcBackup.isBackup(30078, emptyList()))
        assertFalse(NwcBackup.isBackup(30001, listOf(listOf("d", "nwc-wallet-backup"))))
    }

    @Test
    fun `cleared slot`() {
        assertTrue(NwcBackup.isCleared("", NwcBackup.CLEARED_TAGS))
        assertTrue(NwcBackup.isCleared("  \n", listOf(listOf("d", "nwc-wallet-backup"))))
        assertTrue(NwcBackup.isCleared("AgV0ciphertext", listOf(listOf("d", "nwc-wallet-backup"), listOf("deleted", "true"))))
    }

    @Test
    fun `wallet string rule is Wisp's`() {
        assertEquals(uri, NwcBackup.walletString("  $uri\n"))
        val upper = uri.replace("nostr+walletconnect", "NOSTR+WalletConnect")
        assertEquals(upper, NwcBackup.walletString(upper))
        assertNull(NwcBackup.walletString("lnbc1..."))
        assertNull(NwcBackup.walletString("abandon abandon abandon"))
        assertNull(NwcBackup.walletString(""))
    }

    @Test
    fun `saves the trimmed string`() {
        assertEquals(uri, NwcBackup.plaintextForSaving(" $uri "))
        assertNull(NwcBackup.plaintextForSaving("not a wallet"))
    }

    /** The publish guard: the wallet string itself is never treated as ciphertext. */
    @Test
    fun `plaintext never passes as ciphertext`() {
        assertFalse(NwcBackup.isCiphertext(uri))
        assertFalse(NwcBackup.isCiphertext(""))
        assertTrue(NwcBackup.isCiphertext("AgV0b3BzZWNyZXQ="))
    }
}
