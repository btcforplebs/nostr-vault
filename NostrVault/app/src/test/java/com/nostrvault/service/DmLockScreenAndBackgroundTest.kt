package com.nostrvault.service

import com.nostrvault.relay.HavenConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Audit J §1 (no DM text in the tray) and J §2 (DM alerts without opening the app). */
class DmLockScreenAndBackgroundTest {
    private val secret = "meet me at 9, the code is 4471"

    @Test fun aDmInTheTrayNeverShowsItsText() {
        for (type in listOf("dm", "giftwrap")) {
            assertEquals("New message", LocalNotificationService.trayText(type, "Message from Bob", secret))
            assertEquals("You have a new encrypted message", LocalNotificationService.trayText(type, "New message", secret))
        }
    }

    @Test fun otherKindsKeepTheirPreview() {
        assertEquals(secret, LocalNotificationService.trayText("mention", "Bob mentioned you", secret))
    }

    private val owner = "npub1owner"
    private val other = "npub1other"

    @Test fun aLocalKeyVaultListensFromTheRelayService() {
        assertTrue(DMService.listensInBackground(HavenConfig(ownerNpub = owner, hasCompletedSetup = true, signingMode = "local")))
    }

    @Test fun notBeforeSetupIsDone() {
        assertFalse(DMService.listensInBackground(HavenConfig(ownerNpub = owner, hasCompletedSetup = false, signingMode = "local")))
    }

    @Test fun notWhenAmberWouldHaveToSign() {
        // Amber needs the app in front; the owner signs the /chat AUTH even when another account is active.
        assertFalse(DMService.listensInBackground(HavenConfig(ownerNpub = owner, hasCompletedSetup = true, signingMode = "amber")))
        assertFalse(DMService.listensInBackground(HavenConfig(
            ownerNpub = owner, hasCompletedSetup = true, signingMode = "amber",
            activeAccountNpub = other, accountSigningModes = mapOf(other to "local"),
        )))
    }
}
