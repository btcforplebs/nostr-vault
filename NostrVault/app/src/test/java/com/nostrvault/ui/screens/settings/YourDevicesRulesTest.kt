package com.nostrvault.ui.screens.settings

import com.nostrvault.fips.DeviceRole
import com.nostrvault.fips.HomeVaultSender
import com.nostrvault.fips.MyDevice
import com.nostrvault.ui.screens.settings.YourDevicesRules.SyncAction
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class YourDevicesRulesTest {

    private fun device(npub: String, role: DeviceRole) = MyDevice(npub, role, name = "", inReach = false, lastSeen = 0)

    @Test
    fun `only the two vaults get Sync now, each with its existing action`() {
        assertEquals(SyncAction.DESKTOP_SYNC_CHECK, YourDevicesRules.syncAction(DeviceRole.MAC))
        assertEquals(SyncAction.MOBILE_VAULT_SEND, YourDevicesRules.syncAction(DeviceRole.HOME_VAULT))
        assertNull(YourDevicesRules.syncAction(DeviceRole.PHONE))
        assertNull(YourDevicesRules.syncAction(DeviceRole.BROWSER))
    }

    @Test
    fun `vaults come first, then phones, then the browser, keeping list order within a role`() {
        val list = listOf(
            device("p1", DeviceRole.PHONE), device("b", DeviceRole.BROWSER), device("h", DeviceRole.HOME_VAULT),
            device("p2", DeviceRole.PHONE), device("m", DeviceRole.MAC),
        )
        assertEquals(listOf("m", "h", "p1", "p2", "b"), YourDevicesRules.ordered(list).map { it.npub })
        assertEquals(emptyList<MyDevice>(), YourDevicesRules.ordered(emptyList()))
    }

    @Test
    fun `desktop Sync now follows the existing check button and needs a desktop vault to reach`() {
        assertTrue(YourDevicesRules.desktopSyncEnabled("wss://mac", checkRunning = false, checkRequested = false, relayReady = true))
        assertFalse(YourDevicesRules.desktopSyncEnabled("", checkRunning = false, checkRequested = false, relayReady = true))
        assertFalse(YourDevicesRules.desktopSyncEnabled("wss://mac", checkRunning = true, checkRequested = false, relayReady = true))
        assertFalse(YourDevicesRules.desktopSyncEnabled("wss://mac", checkRunning = false, checkRequested = true, relayReady = true))
        assertFalse(YourDevicesRules.desktopSyncEnabled("wss://mac", checkRunning = false, checkRequested = false, relayReady = false))
    }

    @Test
    fun `mobile Sync now is live only while something waits, as Send now`() {
        assertFalse(YourDevicesRules.mobileSendEnabled(HomeVaultSender.State()))
        assertTrue(YourDevicesRules.mobileSendEnabled(HomeVaultSender.State(waiting = 2)))
        assertTrue(YourDevicesRules.mobileSendEnabled(HomeVaultSender.State(publicPending = 1)))
    }
}
