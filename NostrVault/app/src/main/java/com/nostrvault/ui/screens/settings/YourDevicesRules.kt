package com.nostrvault.ui.screens.settings

import com.nostrvault.fips.DeviceRole
import com.nostrvault.fips.HomeVaultSender
import com.nostrvault.fips.MyDevice

/**
 * The rules behind Settings › Your Devices, pure for the tests: which card gets a Sync now button, what it runs, and
 * the order of the cards. Twin of iOS `YourDevicesView`.
 */
object YourDevicesRules {
    /** What a card's Sync now runs. Only the two vaults have one; phones and the browser vault have no button. */
    enum class SyncAction {
        /** The desktop vault sync check (HavenRelaySettingsViewModel.checkSyncWithMac → HavenBridge.requestMacSyncCheck). */
        DESKTOP_SYNC_CHECK,
        /** The mobile vault queue's Send now (FipsMeshViewModel.sendHomeVaultNow → HomeVaultSender.drainSoon). */
        MOBILE_VAULT_SEND,
    }

    fun syncAction(role: DeviceRole): SyncAction? = when (role) {
        DeviceRole.MAC -> SyncAction.DESKTOP_SYNC_CHECK
        DeviceRole.HOME_VAULT -> SyncAction.MOBILE_VAULT_SEND
        DeviceRole.PHONE, DeviceRole.BROWSER -> null
    }

    /** The vaults first (desktop, then mobile), then phones, then the browser vault; My Devices order within a role. */
    fun ordered(devices: List<MyDevice>): List<MyDevice> = devices.sortedBy { ROLE_ORDER.indexOf(it.role) }

    private val ROLE_ORDER = listOf(DeviceRole.MAC, DeviceRole.HOME_VAULT, DeviceRole.PHONE, DeviceRole.BROWSER)

    /** The same rule as the button in MacSyncSection, plus a desktop vault the relay knows how to reach. */
    fun desktopSyncEnabled(configuredMac: String, checkRunning: Boolean, checkRequested: Boolean, relayReady: Boolean): Boolean =
        configuredMac.isNotEmpty() && !checkRunning && !checkRequested && relayReady

    /** The same rule as Mesh › Sync, which shows Send now only while something waits. */
    fun mobileSendEnabled(state: HomeVaultSender.State): Boolean = state.waiting > 0 || state.publicPending > 0

    const val TITLE = "Your Devices"
    const val DEVICES_HEADER = "Your devices"
    const val NO_DEVICES = "No devices yet."
    const val SYNC_NOW = "Sync now"
    const val CONNECT = "Connect a computer or phone"
    const val CONNECT_FOOTER = "Two scans: one shows a code, the other scans it. Your Nostr key never leaves this device."
    const val THIS_PHONE_HEADER = "This phone"
    const val ALWAYS_ON_VAULT = "Use this phone as an always-on vault"
    const val ADVANCED_HEADER = "Advanced"
    const val MESH_ROW = "Mesh"
    const val DESKTOP_BY_ADDRESS_ROW = "Desktop vault by web address"
}
