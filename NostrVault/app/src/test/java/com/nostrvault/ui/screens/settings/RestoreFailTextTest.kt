package com.nostrvault.ui.screens.settings

import org.junit.Assert.assertEquals
import org.junit.Test

/** Settings' notes restore is owner-checked now (code 2 = not your backup), as setup's is. */
class RestoreFailTextTest {
    @Test
    fun `someone else's backup says so`() {
        // Checked against the vault owner, as on iOS (#1757): the words must not say "yours" to another active account.
        assertEquals("This backup isn't this vault's. It holds no notes signed by the vault owner's key.", restoreFailText(2))
        assertEquals("The vault is busy importing. Try again when it ends.", restoreFailText(com.nostrvault.service.RelayImportService.BUSY_CODE))
        assertEquals("Restore failed (code 1).", restoreFailText(1))
    }
}
