package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Test

/** The signer storm (#1739 twin): coming to the front checks the active account only, not every account on the phone. */
class ListWipeForegroundTest {
    @Test
    fun `foreground checks only the active account`() {
        assertEquals(listOf("aa".repeat(32)), ListWipeWatcher.foregroundAccounts("aa".repeat(32)))
        assertEquals(emptyList<String>(), ListWipeWatcher.foregroundAccounts(""))
    }
}
