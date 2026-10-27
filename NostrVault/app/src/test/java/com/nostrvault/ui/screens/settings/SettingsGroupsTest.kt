package com.nostrvault.ui.screens.settings

import com.nostrvault.ui.navigation.Screen
import org.junit.Assert.assertEquals
import org.junit.Test

/** The Settings list keeps the iPhone's groups, order and names (SettingsView.swift `groups`). */
class SettingsGroupsTest {

    @Test
    fun `groups match the iPhone list`() {
        assertEquals(
            listOf("Account", "Feed & Display", "Notifications", "Relays", "Your Vault Relay", "Mesh", "Help", "Advanced"),
            SETTINGS_GROUPS.map { it.title },
        )
        assertEquals(
            listOf(
                "Accounts & Keys", "Blocked", "Recently Deleted", "Following Backup", "Wallet", "Privacy",
                "Feed", "Appearance", "Media & Cache",
                "Notifications",
                "Relays", "Media Servers",
                "Sync with Vault on Mac", "Who Can Reach You", "Import Notes", "Backup & Restore",
                "FIPS Mesh",
                "Tutorials",
                "Proof of Work", "Database & Reset", "Bitcoin On-Chain", "Logs",
            ),
            SETTINGS_GROUPS.flatMap { g -> g.rows.map { it.title } },
        )
    }

    /** The on-chain wallet (address and sweep) is opened only from Advanced (Logen, 2026-10-20). */
    @Test
    fun `the on-chain wallet is only in Advanced`() {
        assertEquals(
            listOf("Advanced"),
            SETTINGS_GROUPS.filter { g -> g.rows.any { it.screen == Screen.BitcoinWallet } }.map { it.title },
        )
    }
}
