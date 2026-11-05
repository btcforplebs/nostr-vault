package com.nostrvault.ui.screens.settings

import org.junit.Assert.assertEquals
import org.junit.Test

/** Settings' notes restore is owner-checked now (code 2 = not your backup), as setup's is. */
class RestoreFailTextTest {
    @Test
    fun `someone else's backup says so`() {
        assertEquals("This backup isn't yours. It holds no notes signed by your key, so nothing was restored.", restoreFailText(2))
        assertEquals("The vault is busy importing. Try again when it ends.", restoreFailText(com.nostrvault.service.RelayImportService.BUSY_CODE))
        assertEquals("Restore failed (code 1).", restoreFailText(1))
    }
}
