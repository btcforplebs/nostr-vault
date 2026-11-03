package com.nostrvault.ui.components

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Messages is a Vault page in the mode pill's dropdown, with its unread count,
 * and no longer an envelope in any Vault toolbar (Logen 2026-11-03).
 */
class VaultMessagesMenuTest {
    private fun src(path: String) = File("src/main/java/com/nostrvault/$path").readText()

    @Test fun `the menu row counts unread messages`() {
        assertNull(VaultMessages(0) {}.badge)
        assertNull(VaultMessages(-1) {}.badge)
        assertEquals("1", VaultMessages(1) {}.badge)
        assertEquals("99", VaultMessages(99) {}.badge)
        assertEquals("99+", VaultMessages(100) {}.badge)
    }

    @Test fun `no Vault toolbar carries the envelope`() {
        for (path in listOf("ui/components/VaultRightPill.kt", "ui/screens/mediagallery/MediaGalleryScreen.kt")) {
            val s = src(path)
            assertFalse(path, s.contains("NostrVaultIcons.Messages"))
            assertFalse(path, s.contains("LocalVaultMessages.current"))
        }
    }

    @Test fun `the mode pill's dropdown opens Messages`() {
        val pill = src("ui/screens/VaultTabScreen.kt").substringAfter("internal fun VaultModePill(")
        assertTrue(pill.contains("LocalVaultMessages.current"))
        assertTrue(pill.contains("Text(\"Messages\", fontWeight = FontWeight.Normal)"))
        assertTrue(pill.contains("messages.open()"))
        // The page it opens is the full-screen inbox route.
        assertTrue(src("ui/screens/VaultTabScreen.kt").contains("VaultMessages(unread = unreadDMs, open = { onNavigate(Screen.DMInbox) })"))
    }
}
