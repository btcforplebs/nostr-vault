package com.nostrvault.relay

// Desktop Vaults on HavenConfig (iOS HavenConfig+DesktopVaults.swift). Kept out of HavenConfig.kt, which is near
// 800 lines.

/**
 * The Vault list in force: the stored one with the one-slot setting taken in ([DesktopVaultsRules.takingInSlot]).
 * The same as [HavenConfig.desktopVaults] once ConfigStore has stored it; computed here too so an edit in the old
 * Haven relay field counts at once.
 */
val HavenConfig.desktopVaultsInEffect: List<DesktopVault>
    get() = DesktopVaultsRules.takingInSlot(
        desktopVaults, macRelayURL, desktopVaultsSlot, fipsMesh.devices, ownerNpub = ownerNpub,
    )

/** This config with [desktopVaultsInEffect] stored and the slot value it took in. `macRelayURL` stays as it is (plan §3 step 5). */
fun HavenConfig.takingInDesktopVaultSlot(): HavenConfig {
    val vaults = desktopVaultsInEffect
    if (vaults == desktopVaults && desktopVaultsSlot == macRelayURL) return this
    return copy(desktopVaults = vaults, desktopVaultsSlot = macRelayURL)
}

/** Every HTTPS Vault's `wss://<base>`, in list order. Feed, blastr and import seed relays put these first, as they did the slot's. */
val HavenConfig.desktopVaultWssURLs: List<String> get() = DesktopVaultsRules.wssURLs(desktopVaultsInEffect)

/** Every HTTPS Vault's `https://<base>`, in list order (Blossom mirrors). */
val HavenConfig.desktopVaultHttpsURLs: List<String> get() = DesktopVaultsRules.httpsURLs(desktopVaultsInEffect)
