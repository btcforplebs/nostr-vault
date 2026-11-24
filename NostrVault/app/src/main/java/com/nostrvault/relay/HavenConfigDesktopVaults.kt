package com.nostrvault.relay

// Desktop Vaults on HavenConfig (iOS HavenConfig+DesktopVaults.swift). Kept out of HavenConfig.kt, which is near
// 800 lines.

/**
 * This device's own mesh npub, as the mesh last saw it ([com.nostrvault.fips.FipsMeshManager]); null before it
 * knows. Never a Vault's mesh address (§2.6). iOS `HavenConfig.storedOwnMeshNpub`.
 */
object OwnMeshNpub {
    @Volatile var value: String? = null
}

/**
 * The Vault list in force: the stored one with the one-slot setting taken in ([DesktopVaultsRules.takingInSlot]),
 * kept in step with My Devices ([DesktopVaultsRules.followingDevices]) and never holding this device's own mesh
 * address ([ownNpub], Tron N2). The same as [HavenConfig.desktopVaults] once ConfigStore has stored it; computed
 * here too so an edit in the old Haven relay field counts at once.
 */
val HavenConfig.desktopVaultsInEffect: List<DesktopVault> get() = desktopVaultsInEffect(OwnMeshNpub.value)

fun HavenConfig.desktopVaultsInEffect(ownNpub: String?): List<DesktopVault> {
    val taken = DesktopVaultsRules.takingInSlot(
        desktopVaults, macRelayURL, desktopVaultsSlot, fipsMesh.devices, ownNpub = ownNpub, ownerNpub = ownerNpub,
    )
    val following = DesktopVaultsRules.followingDevices(taken, fipsMesh.devices, macRelayURL, ownNpub, ownerNpub)
    // Every address deleted on Desktop Vaults stays out (P7, Tron N3 on #2499).
    return DesktopVaultsEditing.applyingRemoved(following, desktopVaultsRemoved)
}

/**
 * The one-slot `macRelayURL` while a Vault still has its address, else "" ([DesktopVaultsEditing.slotInEffect]).
 * Everything derived from the slot reads this, so deleting its Vault on Desktop Vaults turns it off. iOS
 * `HavenConfig.macRelayURLInEffect`.
 */
val HavenConfig.macRelayURLInEffect: String
    get() = DesktopVaultsEditing.slotInEffect(macRelayURL, desktopVaultsInEffect)

/** This config with [desktopVaultsInEffect] stored and the slot value it took in. `macRelayURL` stays as it is (plan §3 step 5). */
fun HavenConfig.takingInDesktopVaultSlot(ownNpub: String? = OwnMeshNpub.value): HavenConfig {
    val vaults = desktopVaultsInEffect(ownNpub)
    if (vaults == desktopVaults && desktopVaultsSlot == macRelayURL) return this
    return copy(desktopVaults = vaults, desktopVaultsSlot = macRelayURL)
}

/** Every HTTPS Vault's `wss://<base>`, in list order. Feed, blastr and import seed relays put these first, as they did the slot's. */
val HavenConfig.desktopVaultWssURLs: List<String> get() = DesktopVaultsRules.wssURLs(desktopVaultsInEffect)

/** Every HTTPS Vault's `https://<base>`, in list order (Blossom mirrors). */
val HavenConfig.desktopVaultHttpsURLs: List<String> get() = DesktopVaultsRules.httpsURLs(desktopVaultsInEffect)

/**
 * The mesh npubs of the Vaults reachable over FIPS, in list order ([DesktopVaultsRules.meshNpubs]): what the relay
 * dials, and so where publish-for-me goes. Replaces [MacSync.macMeshNpub] for routing (P6).
 */
val HavenConfig.desktopVaultMeshNpubs: List<String> get() = desktopVaultMeshNpubs(OwnMeshNpub.value)

fun HavenConfig.desktopVaultMeshNpubs(ownNpub: String?): List<String> =
    DesktopVaultsRules.meshNpubs(desktopVaultsInEffect(ownNpub))

/** Every HTTPS Vault's DM inbox, in list order (§2.2 rule 2; it was the one Mac relay's). */
val HavenConfig.desktopVaultDMInboxURLs: List<String>
    get() = DesktopVaultsRules.dmInboxURLs(desktopVaultsInEffect, macRelayURLInEffect)

// ── Edits from the Desktop Vaults screens (P7; iOS HavenConfig+DesktopVaults.swift) ──

/** Adds [vault] at the end; its addresses leave [HavenConfig.desktopVaultsRemoved]. */
fun HavenConfig.addingDesktopVault(vault: DesktopVault): HavenConfig =
    DesktopVaultsEditing.inserting(vault, desktopVaultsInEffect, desktopVaultsRemoved).let { copy(desktopVaults = it.vaults, desktopVaultsRemoved = it.removed) }

/** Deletes the Vault; its addresses go on [HavenConfig.desktopVaultsRemoved]. */
fun HavenConfig.deletingDesktopVault(id: String): HavenConfig =
    DesktopVaultsEditing.deleting(id, desktopVaultsInEffect, desktopVaultsRemoved).let { copy(desktopVaults = it.vaults, desktopVaultsRemoved = it.removed) }

/**
 * The media servers adoption of a published 10063 never copies into [HavenConfig.blossomMirrors]: every HTTPS Vault's
 * host (its switch's entry, not an ordinary mirror) and the old slot's (Tron must-fix 1 on #2516).
 */
val HavenConfig.vaultMediaServers: List<String>
    get() = (desktopVaultHttpsURLs + macRelayHttpsURL).filter(String::isNotBlank).distinct()

/**
 * After a Delete that took the Vault out of the lists: its host leaves [HavenConfig.blossomMirrors] too, or uploads
 * keep going to the deleted Vault and the next Media Servers Save lists it again (Tron must-fix 1 on #2516).
 */
fun HavenConfig.droppingMirrorsOnHost(host: String?): HavenConfig {
    if (host.isNullOrEmpty()) return this
    val kept = blossomMirrors.filterNot { DesktopVaultsLists.hostKey(it) == host }
    return if (kept.size == blossomMirrors.size) this else copy(blossomMirrors = kept)
}

/** Stores a new order (after a drag) or a rename. */
fun HavenConfig.withDesktopVaults(vaults: List<DesktopVault>): HavenConfig = copy(desktopVaults = DesktopVaultsRules.ordered(vaults))

/** Pairing a device again undoes an earlier delete of its Vault. */
fun HavenConfig.forgettingRemovedDesktopVault(meshNpub: String): HavenConfig {
    val key = DesktopVaultsEditing.removedKeyForMesh(meshNpub)
    return if (key in desktopVaultsRemoved) copy(desktopVaultsRemoved = desktopVaultsRemoved - key) else this
}
