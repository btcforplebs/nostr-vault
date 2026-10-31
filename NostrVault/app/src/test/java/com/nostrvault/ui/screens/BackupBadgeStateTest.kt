package com.nostrvault.ui.screens

import com.nostrvault.service.BlobPresence
import com.nostrvault.service.BlossomBackupSummary
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The menu's Mirror to Blossom now that tiles no longer ask the servers (iOS `mayNeedMirror`). */
class BackupBadgeStateTest {
    @Test fun offeredWhileNoServerHasBeenAsked() {
        assertTrue(BackupBadgeState.mayNeedMirror(isLocal = true, mirrorCount = 2, summary = null))
    }

    @Test fun hiddenOnceEveryServerHasIt() {
        val full = BlossomBackupSummary.of(mapOf("a" to BlobPresence.PRESENT), listOf("a"))
        assertFalse(BackupBadgeState.mayNeedMirror(isLocal = true, mirrorCount = 1, summary = full))
        val half = BlossomBackupSummary.of(mapOf("a" to BlobPresence.PRESENT, "b" to BlobPresence.ABSENT), listOf("a", "b"))
        assertTrue(BackupBadgeState.mayNeedMirror(isLocal = true, mirrorCount = 2, summary = half))
    }

    @Test fun neverWithoutTheFileOrAServer() {
        assertFalse(BackupBadgeState.mayNeedMirror(isLocal = false, mirrorCount = 2, summary = null))
        assertFalse(BackupBadgeState.mayNeedMirror(isLocal = true, mirrorCount = 0, summary = null))
    }
}
