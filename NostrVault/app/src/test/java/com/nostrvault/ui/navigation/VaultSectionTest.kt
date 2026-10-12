package com.nostrvault.ui.navigation

import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** The Vault tab's half across Android killing the app (the photo picker case). */
class VaultSectionTest {
    @Before fun freshProcess() = VaultSection.resetForTest()
    @After fun cleanUp() = VaultSection.resetForTest()

    @Test fun `a fresh launch opens on the Vault list`() {
        assertFalse(VaultSection.showsMedia.value)
        assertTrue(VaultSection.showsActivity.value)
    }

    @Test fun `picking a relay list or Media leaves the Vault list, and Vault comes back`() {
        VaultSection.show(media = false)
        assertFalse(VaultSection.showsActivity.value)
        VaultSection.showActivity()
        assertTrue(VaultSection.showsActivity.value)
        VaultSection.show(media = true)
        assertTrue(VaultSection.showsMedia.value)
        assertFalse(VaultSection.showsActivity.value)
    }

    @Test fun `a tap naming no list keeps the list the tab had`() {
        VaultSection.show(media = true)
        VaultSection.leaveMedia()
        assertFalse(VaultSection.showsMedia.value)
        assertFalse(VaultSection.showsActivity.value)
        VaultSection.showActivity()
        VaultSection.leaveMedia()
        assertTrue(VaultSection.showsActivity.value)
    }

    @Test fun `a restored process comes back on the Vault list or a relay list`() {
        VaultSection.restore(media = false, activity = false)
        assertFalse(VaultSection.showsActivity.value)
        VaultSection.resetForTest()
        VaultSection.restore(media = false, activity = true)
        assertTrue(VaultSection.showsActivity.value)
    }

    @Test fun `a restored process comes back on the half it was on`() {
        VaultSection.restore(media = true)
        assertTrue(VaultSection.showsMedia.value)
    }

    @Test fun `a route that arrived before the restore wins`() {
        // A notification tap relaunched the app: it asked for the relay half
        // before the tab restored its saved Media half.
        VaultSection.show(media = false)
        VaultSection.restore(media = true)
        assertFalse(VaultSection.showsMedia.value)
    }

    @Test fun `a route that arrives after the restore wins`() {
        VaultSection.restore(media = true)
        VaultSection.show(media = false)
        assertFalse(VaultSection.showsMedia.value)
    }

    @Test fun `only the first restore counts`() {
        VaultSection.restore(media = true)
        VaultSection.restore(media = false)
        assertTrue(VaultSection.showsMedia.value)
    }

    // ── Back to the Vault Dashboard ────────────────────────────

    @Test fun `back from a page the dashboard opened returns to it`() {
        VaultSection.show(media = true)
        VaultSection.leaveDashboardForPage()
        assertTrue(VaultSection.returnToDashboard())
        assertTrue(VaultSection.showsMedia.value)
        assertFalse(VaultSection.showsActivity.value)
        assertNull(VaultSection.dashboardTrip.value)
    }

    @Test fun `leaving media yourself ends the trip`() {
        VaultSection.leaveDashboardForPage()
        VaultSection.leaveMedia()
        assertFalse(VaultSection.returnToDashboard())
    }

    @Test fun `picking another list yourself ends the trip`() {
        VaultSection.leaveDashboardForPage()
        VaultSection.show(media = true)
        assertNull(VaultSection.dashboardTrip.value)
        assertFalse(VaultSection.returnToDashboard())
    }

    @Test fun `returning twice only reopens once`() {
        VaultSection.leaveDashboardForPage()
        assertTrue(VaultSection.returnToDashboard())
        assertFalse(VaultSection.returnToDashboard())
        assertTrue(VaultSection.showsActivity.value)
    }

    @Test fun `with no trip, back does what it would`() {
        assertFalse(VaultSection.returnToDashboard())
        assertTrue(VaultSection.showsActivity.value)
    }
}
