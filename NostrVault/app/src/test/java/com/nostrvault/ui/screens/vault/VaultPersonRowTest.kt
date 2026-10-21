package com.nostrvault.ui.screens.vault

import com.nostrvault.data.model.FeedProfile
import org.junit.Assert.assertEquals
import org.junit.Test

/** The Vault search's person row titles and middle cut (iOS `ProfileResultRow`). */
class VaultPersonRowTest {
    private val npub = { _: String -> "npub1abcdefghijklmnopqrstuvwxyz" }

    @Test fun `a named profile leads with its name`() {
        assertEquals("Alice", vaultPersonTitle(FeedProfile(pubkey = "ab", displayName = "Alice"), npub))
        assertEquals("alice", vaultPersonTitle(FeedProfile(pubkey = "ab", name = "alice"), npub))
    }

    @Test fun `no profile yet shows the whole npub`() {
        assertEquals("npub1abcdefghijklmnopqrstuvwxyz", vaultPersonTitle(FeedProfile(pubkey = "ab"), npub))
    }

    @Test fun `no npub falls back to the best name`() {
        assertEquals("abcdef12...", vaultPersonTitle(FeedProfile(pubkey = "abcdef1234"), { null }))
    }

    @Test fun `middle cut keeps both ends`() {
        assertEquals("npub1…wxyz", middleCut("npub1abcdefghijklmnopqrstuvwxyz", 9))
        assertEquals("short", middleCut("short", 10))
        assertEquals("…", middleCut("abc", 0))
    }
}
