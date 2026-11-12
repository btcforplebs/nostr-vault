package com.nostrvault.ui.screens.settings

import com.nostrvault.fips.DeviceRole
import com.nostrvault.fips.HomeVaultSender
import com.nostrvault.fips.MyDevice

/**
 * The rules behind Settings › Your Devices, pure for the tests: which card gets a Sync now button, what it runs, and
 * the order of the cards. Twin of iOS `YourDevicesSettingsView` / `YourDevicesLogic`.
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

    // Full copy (multi-Mac rules §3). Twins of iOS YourDevicesLogic.

    /**
     * Whether this phone keeps every own note and file: mobile vault mode always does, else the switch, which is on
     * unless the owner turned it off (Logen's pick 1, 2026-11-12: new and existing phones start on).
     */
    fun keepsFullCopy(mobileVault: Boolean, stored: Boolean?): Boolean = mobileVault || stored != false

    /** Mobile vault mode turns the switch on and locks it. */
    fun fullCopyLocked(mobileVault: Boolean): Boolean = mobileVault

    const val FULL_COPY_LOCKED_LINE = "A mobile vault keeps everything."

    /** Whether a catch-up moves files, not only notes: never for a light phone; on Wi-Fi only while that is on (default). */
    fun catchUpMovesFiles(fullCopy: Boolean, wifiOnly: Boolean?, onWiFi: Boolean): Boolean =
        fullCopy && (onWiFi || wifiOnly == false)

    /** The host of an https/wss URL or bare domain, lowercased, without port or path; null without one. */
    fun host(text: String): String? {
        var t = text.trim().lowercase()
        if (t.isEmpty()) return null
        if (!t.contains("://")) t = "https://$t"
        return runCatching { java.net.URI(t).host }.getOrNull()?.takeIf { it.isNotEmpty() }
    }

    /**
     * Which own device is public on the web: the one whose domain is the first of the owner's https entries in the
     * newest 10063 that is one of theirs (multi-Mac rules §3.3). [domains]: each own device's domain by mesh npub.
     */
    fun webDevice(serverList: List<String>, domains: Map<String, String>): String? {
        val byHost = mutableMapOf<String, String>()
        domains.forEach { (npub, domain) -> host(domain)?.let { byHost.putIfAbsent(it, npub) } }
        return serverList.asSequence()
            .filter { it.lowercase().startsWith("https://") }
            .mapNotNull { host(it)?.let(byHost::get) }
            .firstOrNull()
    }

    const val TITLE = "Your Devices"
    const val DEVICES_HEADER = "Your devices"
    const val NO_DEVICES = "No devices yet."
    const val SYNC_NOW = "Sync now"
    const val CONNECT = "Connect a computer or phone"
    const val CONNECT_FOOTER = "Two scans: one shows a code, the other scans it. Your Nostr key never leaves this device."
    const val THIS_PHONE_HEADER = "This phone"
    const val ALWAYS_ON_VAULT = "Use this phone as an always-on vault"
    const val ALWAYS_ON_SUBTITLE = "Mobile vault mode: for a spare phone on a charger"
    const val FULL_COPY = "Keep a full copy on this phone"
    const val FULL_COPY_SUBTITLE = "Every photo and file from your other devices shows up here. Off: notes only, files when you open them."
    const val WIFI_ONLY = "Wi-Fi only"
    const val WIFI_ONLY_SUBTITLE = "Catching up on files waits for Wi-Fi. What you add here always goes out right away."
    /**
     * The power notice under the switch, worded for Android (Logen 2026-11-12): iPhone's says charger, app open,
     * screen kept on, pauses when you leave the app; Android runs it in the background, so it says charger and
     * background (as docs/mesh/home-vault: it keeps serving while your vault runs, and after a restart).
     */
    const val POWER_NOTICE = "Leave this phone on a charger. Mobile vault mode keeps running in the background while " +
        "your vault runs, and after a restart. Your devices reach it in full."
    const val ADVANCED_HEADER = "Advanced"
    const val MESH_ROW = "Mesh"
    const val DESKTOP_BY_ADDRESS_ROW = "Desktop vault by web address"
}
