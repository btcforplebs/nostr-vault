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

    // ── Status: never claim "not saved" without proof (iOS NWCBackupTests) ──

    private val slot = NwcBackup.Slot("AgV0ciphertext", listOf(listOf("d", "nwc-wallet-backup")), 1_792_000_000L)

    /** Only an answer says "nothing saved"; one is enough, so a silent Mac relay can't block it. */
    @Test
    fun `no answer is unknown, one answer is empty`() {
        assertEquals(NwcBackup.Status.Unknown, NwcBackup.status(null, false, NwcBackup.Read.NotTried))
        assertEquals(NwcBackup.Status.Empty, NwcBackup.status(null, true, NwcBackup.Read.NotTried))
    }

    @Test
    fun `cleared slot is empty`() {
        val cleared = NwcBackup.Slot("", NwcBackup.CLEARED_TAGS, 1L)
        assertEquals(NwcBackup.Status.Empty, NwcBackup.status(cleared, true, NwcBackup.Read.NotTried))
    }

    /** A slot that wasn't or couldn't be read still has a wallet in it: Remove is offered, never "off". */
    @Test
    fun `unread slot still has a wallet`() {
        val pending = NwcBackup.status(slot, true, NwcBackup.Read.NotTried)
        assertEquals(NwcBackup.Status.NeedsSigner(1_792_000_000L), pending)
        assertTrue(pending.hasSlot)
        val failed = NwcBackup.status(slot, true, NwcBackup.Read.Failed)
        assertEquals(NwcBackup.Status.Unreadable(1_792_000_000L), failed)
        assertTrue(failed.hasSlot)
        assertEquals(NwcBackup.Status.Unreadable(1_792_000_000L), NwcBackup.status(slot, true, NwcBackup.Read.Plaintext("not a wallet")))
        assertFalse(NwcBackup.Status.Unknown.hasSlot)
        assertFalse(NwcBackup.Status.Empty.hasSlot)
    }

    @Test
    fun `read slot is saved`() {
        assertEquals(NwcBackup.Status.Saved(uri, 1_792_000_000L), NwcBackup.status(slot, true, NwcBackup.Read.Plaintext(" $uri\n")))
    }

    /** The wallet string is a spending secret: it never shows up in a log. */
    @Test
    fun `status and read strings hide the wallet`() {
        assertFalse(NwcBackup.Status.Saved(uri, 5).toString().contains("walletconnect"))
        assertFalse(NwcBackup.Read.Plaintext(uri).toString().contains("walletconnect"))
    }

    /** Remove whenever a wallet may be on the account; not where nothing is, nor under an ON switch. */
    @Test
    fun `remove is offered where a wallet may be`() {
        assertTrue(NwcBackup.Status.Unknown.offersRemove(""))
        assertTrue(NwcBackup.Status.NeedsSigner(1).offersRemove(uri))
        assertTrue(NwcBackup.Status.Unreadable(1).offersRemove(""))
        assertTrue(NwcBackup.Status.Saved(uri, 1).offersRemove(""))
        assertTrue(NwcBackup.Status.Saved(uri, 1).offersRemove("nostr+walletconnect://other"))
        assertFalse(NwcBackup.Status.Saved(uri, 1).offersRemove(uri))
        assertFalse(NwcBackup.Status.Empty.offersRemove(""))
        assertFalse(NwcBackup.Status.Empty.offersRemove(uri))
    }
}
