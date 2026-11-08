package com.nostrvault.ui.screens.settings

import com.nostrvault.ui.navigation.Screen
import org.junit.Assert.assertEquals
import org.junit.Test

/** The Settings list keeps the iPhone's groups, order and names (SettingsView.swift `groups`). */
class SettingsGroupsTest {

    @Test
    fun `groups match the iPhone list`() {
        assertEquals(
            listOf("Account", "Feed & Display", "Notifications", "Relays", "Your Vault", "Mesh", "Help", "Advanced"),
            SETTINGS_GROUPS.map { it.title },
        )
        assertEquals(
            listOf(
                "Accounts & Keys", "Blocked", "Recently Deleted", "Following Backup", "List backups", "Wallet", "Privacy",
                "Feed", "Appearance", "Media & Cache",
                "Notifications",
                "Relays", "Media Servers",
                "Desktop vault sync", "Who Can Reach You", "Import Notes", "Backup & Restore",
                "Mesh",
                "Tutorials",
                "Proof of Work", "Database & Reset", "Bitcoin On-Chain", "Logs",
            ),
            SETTINGS_GROUPS.flatMap { g -> g.rows.map { it.title } },
        )
    }

    /** List backups opens from Settings too, not only the Vault dashboard (iPhone/Mac #1579). */
    @Test
    fun `list backups is in Account`() {
        assertEquals(
            listOf("Account"),
            SETTINGS_GROUPS.filter { g -> g.rows.any { it.screen == Screen.ListBackup } }.map { it.title },
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
