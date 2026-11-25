package com.nostrvault.relay

import com.nostrvault.fips.DeviceRole
import com.nostrvault.fips.FipsDevice
import com.nostrvault.fips.HomeVaultRules
import com.nostrvault.fips.MyDevicesRules
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import java.security.MessageDigest

/**
 * The desktop Vault list: migration from the one-slot [HavenConfig.macRelayURL], the addresses the relay and the
 * derived relay lists get, and the engine's per-Vault status file name (PLANS/NV_DESKTOP_VAULTS_PLAN.md §2.1, §3).
 * Pure, so the unit tests check it on docs/fixtures/desktop-vaults. iOS twin: `Models/DesktopVaultsLogic.swift`.
 */
object DesktopVaultsRules {

    /** A Vault's id, made from the address it was first made with, so the same Vault made on two devices gets the same id. */
    fun idForHost(host: String) = "https:$host"
    fun idForMesh(npub: String) = "mesh:$npub"

    /**
     * `https://<base>` for a typed web address, null for anything else. The base is kept as typed but for the scheme
     * and trailing slashes, exactly as the slot's ([HavenConfig.macRelayNormalizedBase]), so the relay lists get the
     * same address they did.
     */
    fun httpsURL(raw: String): String? {
        if (HomeVaultRules.meshNpubFromInput(raw) != null || DesktopVaultsLists.hostKey(raw) == null) return null
        return "https://${base(raw)}"
    }

    /** The address without its scheme and trailing slashes. */
    fun base(raw: String): String {
        var url = raw.trim()
        for (scheme in listOf("wss://", "ws://", "https://", "http://")) {
            if (url.lowercase().startsWith(scheme)) {
                url = url.drop(scheme.length)
                break
            }
        }
        while (url.endsWith("/")) url = url.dropLast(1)
        return url
    }

    /** The Vaults with `order` renumbered 0, 1, 2… in their current order (ties by id, §2.6). */
    fun ordered(vaults: List<DesktopVault>): List<DesktopVault> =
        vaults.sortedWith(compareBy({ it.order }, { it.id })).renumbered()

    private fun List<DesktopVault>.renumbered() = mapIndexed { i, vault -> vault.copy(order = i) }

    // ── Migration (§3) and the old tab ───────────────────────────

    /** What the slot holds: a web host, a mesh npub or nothing. */
    sealed class SlotAddress {
        object None : SlotAddress()
        data class Web(val host: String) : SlotAddress()
        data class Mesh(val npub: String) : SlotAddress()

        companion object {
            fun of(raw: String): SlotAddress {
                if (raw.isBlank()) return None
                HomeVaultRules.meshNpubFromInput(raw)?.let { return Mesh(it) }
                return DesktopVaultsLists.hostKey(raw)?.let(::Web) ?: None
            }
        }
    }

    /**
     * The Vault list after taking in the one-slot setting.
     *
     * [taken] is the slot value the list last took in, null when it never has. The first time (§3), with no Vaults
     * yet: a slot holding a mesh npub becomes a FIPS-only Vault; a slot holding a web address becomes an HTTPS-only
     * Vault, merged with the owner's Mac whose `domain` has that host; every other Mac of the owner's becomes a
     * FIPS-only Vault, in [macs] order after the slot's. Nothing is published and `macRelayURL` is
     * never written (§3 steps 4-5).
     *
     * Until the Desktop Vaults screens replace the old Haven relay field (P7), that field still edits the slot, so a
     * later change to it moves the Vault that came from the old value, and a path edit on the same host moves its
     * address (Tron M1 on #2499). Every other Vault stays as it is.
     */
    fun takingInSlot(
        vaults: List<DesktopVault>, slot: String, taken: String?, devices: List<FipsDevice>,
        ownNpub: String? = null, ownerNpub: String = "",
    ): List<DesktopVault> {
        if (taken == null) return if (vaults.isEmpty()) migrated(slot, devices, ownNpub, ownerNpub) else ordered(vaults)
        val old = SlotAddress.of(taken)
        val new = SlotAddress.of(slot)
        val out = ordered(vaults).toMutableList()
        if (old == new) {
            // The slot's address held by no Vault (the stored list was lost or dropped it): take it in again as new,
            // so the owner's Mac stays a Vault and out of "Delete from mirrors" (Tron M1 on #2500).
            if (!holds(out, new, ownNpub)) return out.also { addSlot(it, new, slot, devices, ownNpub, ownerNpub) }.renumbered()
            // Same host, new path or spelling (`/haven` to `/relay`): the Vault takes the new address, as MAC_RELAY_URL does.
            if (new !is SlotAddress.Web || httpsURL(taken) == httpsURL(slot)) return vaults
            val i = vaults.indexOfFirst { it.hostKey == new.host }
            if (i < 0) return vaults
            return vaults.toMutableList().also { it[i] = it[i].copy(httpsURL = httpsURL(slot)) }
        }
        // The old address leaves the Vault that had it.
        when (old) {
            is SlotAddress.Web -> out.indexOfFirst { it.hostKey == old.host }.takeIf { it >= 0 }?.let { out[it] = out[it].copy(httpsURL = null) }
            is SlotAddress.Mesh -> {
                val i = out.indexOfFirst { it.meshNpub == old.npub }
                if (i >= 0 && out[i].httpsURL == null && devices.none { it.npub == old.npub && it.role == DeviceRole.MAC }) {
                    out[i] = out[i].copy(meshNpub = null)
                }
            }
            SlotAddress.None -> Unit
        }
        out.removeAll { it.meshNpub == null && it.httpsURL == null }
        if (!holds(out, new, ownNpub)) addSlot(out, new, slot, devices, ownNpub, ownerNpub)
        return out.renumbered()
    }

    /** Whether a Vault already has the slot's address (nothing to hold for an empty slot or this device's own npub). */
    private fun holds(vaults: List<DesktopVault>, address: SlotAddress, ownNpub: String?): Boolean = when (address) {
        is SlotAddress.Web -> vaults.any { it.hostKey == address.host }
        is SlotAddress.Mesh -> address.npub == ownNpub || vaults.any { it.meshNpub == address.npub }
        SlotAddress.None -> true
    }

    /** The slot's address goes to the Mac whose domain it is, else to a new Vault, first. */
    private fun addSlot(
        out: MutableList<DesktopVault>, address: SlotAddress, slot: String, devices: List<FipsDevice>,
        ownNpub: String?, ownerNpub: String,
    ) {
        val device = (address as? SlotAddress.Web)?.let { macDevice(it.host, devices, ownNpub, ownerNpub) }
        val i = device?.let { d -> out.indexOfFirst { it.meshNpub == d.npub } } ?: -1
        if (i >= 0) out[i] = out[i].copy(httpsURL = httpsURL(slot))
        else out.add(0, vaultForSlot(address, slot, devices, ownNpub, ownerNpub))
    }

    fun migrated(slot: String, devices: List<FipsDevice>, ownNpub: String?, ownerNpub: String = ""): List<DesktopVault> {
        val out = mutableListOf<DesktopVault>()
        val address = SlotAddress.of(slot)
        val slotNpub = (address as? SlotAddress.Mesh)?.npub
        // This device's own address is never a Vault of its own.
        if (address != SlotAddress.None && !(slotNpub != null && slotNpub == ownNpub)) {
            out += vaultForSlot(address, slot, devices, ownNpub, ownerNpub)
        }
        for (npub in macs(devices, slotNpub, ownNpub, ownerNpub)) {
            if (out.any { it.meshNpub == npub }) continue
            out += DesktopVault(id = idForMesh(npub), name = devices.firstOrNull { it.npub == npub }?.name.orEmpty(), meshNpub = npub)
        }
        return out.renumbered()
    }

    /** The slot's Mac first, then the owner's Macs in My Devices order, each once, never this device. iOS MeshDevicesLogic.macs. */
    fun macs(devices: List<FipsDevice>, slotNpub: String?, ownNpub: String?, ownerNpub: String = ""): List<String> {
        val out = mutableListOf<String>()
        if (slotNpub != null && slotNpub != ownNpub) out += slotNpub
        devices.filter { it.role == DeviceRole.MAC && MyDevicesRules.isOwners(it.linkedBy, ownerNpub) }
            .map { it.npub }
            .filter { it != ownNpub && it !in out }
            .forEach { out += it }
        return out
    }

    private fun macDevice(host: String, devices: List<FipsDevice>, ownNpub: String?, ownerNpub: String): FipsDevice? =
        devices.firstOrNull {
            it.role == DeviceRole.MAC && it.npub != ownNpub && MyDevicesRules.isOwners(it.linkedBy, ownerNpub) &&
                DesktopVaultsLists.hostKey(it.domain) == host
        }

    private fun vaultForSlot(
        address: SlotAddress, typed: String, devices: List<FipsDevice>, ownNpub: String?, ownerNpub: String,
    ): DesktopVault = when (address) {
        is SlotAddress.Web -> macDevice(address.host, devices, ownNpub, ownerNpub)?.let { d ->
            DesktopVault(id = idForMesh(d.npub), name = d.name, meshNpub = d.npub, httpsURL = httpsURL(typed))
        } ?: DesktopVault(id = idForHost(address.host), httpsURL = httpsURL(typed))
        is SlotAddress.Mesh -> DesktopVault(
            id = idForMesh(address.npub), name = devices.firstOrNull { it.npub == address.npub }?.name.orEmpty(),
            meshNpub = address.npub,
        )
        SlotAddress.None -> DesktopVault(id = "")
    }

    // ── Following My Devices and routing (P6, iOS P3 #2506) ──────

    /**
     * The list kept in step with My Devices after migration (Tron N1, N2 on #2499), since routing reads it:
     * - this device's own npub is never a Vault's mesh address (§2.6);
     * - a Vault's mesh address goes when its `.mac` device leaves My Devices, unless the slot still names it; a Vault
     *   left with no address goes;
     * - an owner's `.mac` device with no Vault becomes one, on the HTTPS Vault whose host is its domain, else as a
     *   new FIPS-only Vault at the end.
     * Clearing the old field takes only the slot's address off (N3): a Mac still in My Devices stays a Vault.
     * iOS DesktopVaultsLogic.followingDevices.
     */
    /**
     * The mesh addresses [followingDevices] lets a Vault keep: an owner-linked `MAC` in My Devices, or the slot's npub,
     * never this device's own. The settings copy reads the same set to tell an address this device dropped (can't hold,
     * so carried as the file has it) from one it deleted (#2521).
     */
    fun holdableMeshNpubs(devices: List<FipsDevice>, slot: String, ownNpub: String?, ownerNpub: String = ""): Set<String> =
        macs(devices, (SlotAddress.of(slot) as? SlotAddress.Mesh)?.npub, ownNpub, ownerNpub).toSet()

    fun followingDevices(
        vaults: List<DesktopVault>, devices: List<FipsDevice>, slot: String, ownNpub: String?, ownerNpub: String = "",
    ): List<DesktopVault> {
        val holdable = holdableMeshNpubs(devices, slot, ownNpub, ownerNpub)
        val out = ordered(vaults).map { vault ->
            val npub = vault.meshNpub?.let(HomeVaultRules::meshNpubFromInput) ?: return@map vault
            if (npub !in holdable) vault.copy(meshNpub = null) else vault
        }.filterNot { it.meshNpub == null && it.httpsURL == null }.toMutableList()
        for (npub in macs(devices, null, ownNpub, ownerNpub)) {
            if (out.any { it.meshNpub?.let(HomeVaultRules::meshNpubFromInput) == npub }) continue
            val device = devices.firstOrNull { it.npub == npub }
            val host = device?.domain?.let(DesktopVaultsLists::hostKey)
            val i = if (host == null) -1 else out.indexOfFirst { it.hostKey == host && it.meshNpub == null }
            if (i >= 0) {
                out[i] = out[i].copy(meshNpub = npub, name = out[i].name.ifEmpty { device?.name.orEmpty() })
            } else {
                out += DesktopVault(id = idForMesh(npub), name = device?.name.orEmpty(), meshNpub = npub, order = out.size)
            }
        }
        return out.renumbered()
    }

    /** The mesh npubs of the Vaults reachable over FIPS, in list order, each once: the dial order (§2.2 rule 3). */
    fun meshNpubs(vaults: List<DesktopVault>): List<String> {
        val seen = mutableSetOf<String>()
        return ordered(vaults).mapNotNull { vault ->
            vault.meshNpub?.let(HomeVaultRules::meshNpubFromInput)?.takeIf { seen.add(it) }
        }
    }

    /**
     * When the relay dials the mesh Vaults (Tron M1 on #2506). Only with FIPS on. Before the start only when the slot
     * itself is a mesh npub: that Vault has no other way in. Any other mesh Vault is dialed after the relay is up
     * over wss ([MeshVaultDial]), so a paired Mac out of reach never holds a start.
     */
    enum class MeshDial { NONE, BEFORE_START, AFTER_START }

    fun meshDial(fipsOn: Boolean, slot: String, meshNpubs: List<String>): MeshDial = when {
        !fipsOn || meshNpubs.isEmpty() -> MeshDial.NONE
        SlotAddress.of(slot) is SlotAddress.Mesh -> MeshDial.BEFORE_START
        else -> MeshDial.AFTER_START
    }

    /** One total wait for all the dials of a start (Tron M1): N unreachable Macs no longer cost N×. */
    const val MESH_DIAL_BUDGET_MS = 10_000L

    /**
     * The first of [npubs], in order, whose [dial] answers inside one shared [budgetMs]. A dial still running when the
     * budget ends is left to finish on its own (the FFI dial can't be interrupted) and its answer is dropped. Blocks.
     */
    fun firstAnswering(npubs: List<String>, budgetMs: Long, dial: (String) -> String?): Pair<String, String>? {
        val deadline = System.nanoTime() + budgetMs * 1_000_000
        val pool = java.util.concurrent.Executors.newCachedThreadPool { r -> Thread(r, "mesh-vault-dial").apply { isDaemon = true } }
        try {
            for (npub in npubs) {
                val left = (deadline - System.nanoTime()) / 1_000_000
                if (left <= 0) return null
                val url = runCatching { pool.submit<String?> { dial(npub) }.get(left, java.util.concurrent.TimeUnit.MILLISECONDS) }.getOrNull()
                if (url != null) return npub to url
            }
            return null
        } finally {
            pool.shutdown()
        }
    }

    /**
     * Every HTTPS Vault's DM inbox, `wss://<base>/inbox`, in list order (§2.2 rule 2): where other people send DMs
     * and the own sent copies go. Left out: a home-network address, which others can't reach, and the slot when it
     * was typed as plain `ws://` or `http://`. iOS DesktopVaultsLogic.dmInboxURLs.
     */
    fun dmInboxURLs(vaults: List<DesktopVault>, slot: String): List<String> {
        val typed = slot.trim().lowercase()
        val plainHost = if (typed.startsWith("ws://") || typed.startsWith("http://")) DesktopVaultsLists.hostKey(typed) else null
        return bases(vaults).mapNotNull { (host, base) ->
            if (host == plainHost || DMInbox.isPrivateNetworkHost(base)) null else "wss://$base/inbox"
        }
    }

    /**
     * Whether config.json's `desktopVaults` is there but read as empty when it should not have: not a list at all
     * (`null` included), or a list none of whose Vaults this build can read ([LossyDesktopVaultList]). ConfigStore
     * then sets `desktopVaultsSlot` to null and the slot is migrated again (Tron S1 on #2499, M1 on #2500).
     */
    fun unreadableList(configText: String): Boolean = runCatching {
        val value = (Json.parseToJsonElement(configText) as JsonObject)["desktopVaults"] ?: return@runCatching false
        if (value !is JsonArray) return@runCatching true
        value.isNotEmpty() && Json.decodeFromJsonElement(LossyDesktopVaultList, value).isEmpty()
    }.getOrDefault(false)

    // ── Addresses the relay and the derived lists get ────────────

    /** Every HTTPS Vault's `wss://<base>`, in list order, one per host. */
    fun wssURLs(vaults: List<DesktopVault>): List<String> = bases(vaults).map { "wss://${it.second}" }

    /** Every HTTPS Vault's `https://<base>`, in list order, one per host. */
    fun httpsURLs(vaults: List<DesktopVault>): List<String> = bases(vaults).map { "https://${it.second}" }

    private fun bases(vaults: List<DesktopVault>): List<Pair<String, String>> {
        val seen = mutableSetOf<String>()
        return ordered(vaults).mapNotNull { vault ->
            val url = vault.httpsURL ?: return@mapNotNull null
            val host = vault.hostKey ?: return@mapNotNull null
            if (!seen.add(host)) null else host to base(url)
        }
    }

    /**
     * DESKTOP_VAULT_URLS for the relay (haven-go macsync.go): every HTTPS Vault but the one MAC_RELAY_URL already
     * names, comma separated, "" when there is none. Always passed, empty included, because the engine never clears
     * a host env key (Tidy, P1).
     *
     * [slot] is MAC_RELAY_URL as passed. A Vault it reaches over the mesh keeps its web address here (Tron M2 on
     * #2506): the mesh link ends when the engine stops and nothing dials again until the next start, so its wss is
     * the fallback (§2.2: mesh first, wss as fallback). [typed]: the old field's value; a slot typed as plain
     * `ws://`/`http://` that lands here keeps `ws://`, as MAC_RELAY_URL kept it.
     */
    fun envList(vaults: List<DesktopVault>, slot: String, typed: String = ""): String {
        val slotHost = (SlotAddress.of(slot) as? SlotAddress.Web)?.host
        val lower = typed.trim().lowercase()
        val plainHost = if (lower.startsWith("ws://") || lower.startsWith("http://")) DesktopVaultsLists.hostKey(lower) else null
        return bases(vaults).filter { it.first != slotHost }
            .joinToString(",") { (if (it.first == plainHost) "ws://" else "wss://") + it.second }
    }

    /** `relays` with each Vault relay not already in it put in front, in Vault list order. One already listed keeps its place, as the slot did. */
    fun withVaultsFirst(relays: List<String>, vaults: List<String>): List<String> = vaults.filter { it !in relays } + relays

    // ── Engine status files ──────────────────────────────────────

    /**
     * The engine's per-Vault status file for [base] (haven-go macSyncStatusFile): the URL with the scheme kept, `://`
     * as `_` and anything but letters, digits, `.` and `-` as `_`; a name over 200 bytes is the SHA-256 hex of [base].
     */
    fun statusFileName(base: String): String {
        var name = base.replaceFirst("://", "_")
        val sb = StringBuilder()
        var i = 0
        while (i < name.length) {
            val cp = name.codePointAt(i)
            val keep = cp == '.'.code || cp == '-'.code || cp in '0'.code..'9'.code || cp in 'a'.code..'z'.code || cp in 'A'.code..'Z'.code
            sb.append(if (keep) cp.toChar() else '_')
            i += Character.charCount(cp)
        }
        name = sb.toString()
        if (name.toByteArray(Charsets.UTF_8).size > 200) {
            name = MessageDigest.getInstance("SHA-256").digest(base.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
        }
        return "mac_sync_status-$name.json"
    }
}
