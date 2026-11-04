package com.nostrvault.ui.screens.settings

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Reveal Private Key also copies the key locked with a password (NIP-49; NDK check step 4, Logen 2026-11-04). */
class LockedKeyExportTest {
    private val hexOf = { nsec: String -> if (nsec == "nsec1ok") "ab".repeat(32) else null }

    @Test fun `locks the revealed key with the password`() {
        var seen: Pair<String, String>? = null
        val locked = LockedKeyExport.lock("nsec1ok", "correct horse", hexOf) { hex, pw -> seen = hex to pw; "ncryptsec1locked" }
        assertEquals("ncryptsec1locked", locked)
        assertEquals("ab".repeat(32) to "correct horse", seen)
    }

    @Test fun `copies nothing it can't lock`() {
        assertNull(LockedKeyExport.lock("nsec1ok", "", hexOf) { _, _ -> "ncryptsec1x" })
        assertNull(LockedKeyExport.lock("nsec1bad", "correct horse", hexOf) { _, _ -> "ncryptsec1x" })
        assertNull(LockedKeyExport.lock("nsec1ok", "correct horse", hexOf) { _, _ -> throw IllegalStateException("go") })
        assertNull(LockedKeyExport.lock("nsec1ok", "correct horse", hexOf) { _, _ -> "nsec1notlocked" })
    }

    @Test fun `a new lock password is 8 or more, typed the same twice`() {
        assertEquals("Password must be at least 8 characters", LockedKeyExport.passwordProblem("short", "short"))
        assertEquals("Passwords do not match", LockedKeyExport.passwordProblem("longenough", "longenougx"))
        assertEquals("", LockedKeyExport.passwordProblem("longenough", "longenough"))
    }
}
