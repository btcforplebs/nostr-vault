package com.nostrvault.ui.screens.settings

import org.junit.Assert.assertEquals
import org.junit.Test

/** The Settings list keeps the iPhone's groups, order and names (SettingsView.swift `groups`). */
class SettingsGroupsTest {

    @Test
    fun `groups match the iPhone list`() {
        assertEquals(
            listOf("Account", "Feed & Display", "Notifications", "Relays", "Your Vault Relay", "Help", "Advanced"),
            SETTINGS_GROUPS.map { it.title },
        )
        assertEquals(
            listOf(
                "Accounts & Keys", "Blocked", "Following Backup", "Wallet",
                "Feed", "Appearance", "Media & Cache",
                "Notifications",
                "Relays", "Media Servers",
                "Sync with Mac", "Who Can Reach You", "Import Notes", "Backup & Restore",
                "Tutorials",
                "Proof of Work", "Database & Reset", "Logs",
            ),
            SETTINGS_GROUPS.flatMap { g -> g.rows.map { it.title } },
        )
    }
}
