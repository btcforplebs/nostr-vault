package com.nostrvault.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** A multi-account Vault line stacks up to 3 pictures, then +N (iOS #1772). */
class VaultAccountStackTest {
    @Test
    fun `three pictures, then plus N`() {
        assertNull(accountStackMore(1))
        assertNull(accountStackMore(3))
        assertEquals("+1", accountStackMore(4))
        assertEquals("+4", accountStackMore(7))
        assertEquals("Reply or react as", PICK_ACCOUNT_TITLE)
    }
}
