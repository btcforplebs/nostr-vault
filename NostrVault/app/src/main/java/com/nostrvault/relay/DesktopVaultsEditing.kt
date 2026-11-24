package com.nostrvault.relay

import com.nostrvault.fips.HomeVaultRules

/**
 * What the Desktop Vaults screens do to the Vault list (Desktop Vaults P7, PLANS/NV_DESKTOP_VAULTS_PLAN.md §2.1, §2.5
 * rules 4 and 8, §2.7): add, change an address, rename, drag, delete. Pure, so unit tests check it. iOS twin:
 * `Models/DesktopVaultsEditing.swift` (P4 #2511).
 *
 * A deleted Vault leaves its addresses in `removed` ([removedKey]), so the list's own followers
 * ([DesktopVaultsRules.takingInSlot], which re-adds the old slot's address, and [DesktopVaultsRules.followingDevices],
 * which adds every paired Mac) don't put it straight back. Adding the address again, or pairing that device again,
 * takes it off `removed`. This is how a Vault is turned off once the old one-slot field is gone (Tron N3 on #2499).
 */
object DesktopVaultsEditing {

    // ── Removed addresses ──

    /** The key `removed` holds for a web host or a mesh npub (the same spelling as a Vault id made from it). */
    fun removedKeyForHost(host: String): String = DesktopVaultsRules.idForHost(host)
    fun removedKeyForMesh(npub: String): String = DesktopVaultsRules.idForMesh(npub)

    private fun npubOf(vault: DesktopVault): String? = vault.meshNpub?.let(HomeVaultRules::meshNpubFromInput)

    /** Every key a Vault's addresses have. */
    fun removedKeys(vault: DesktopVault): List<String> =
        listOfNotNull(npubOf(vault)?.let(::removedKeyForMesh), vault.hostKey?.let(::removedKeyForHost))

    /** The Vaults with every removed address taken off; a Vault left with no address goes. Order is kept and renumbered. */
    fun applyingRemoved(vaults: List<DesktopVault>, removed: List<String>): List<DesktopVault> {
        if (removed.isEmpty()) return vaults
        val gone = removed.toSet()
        val out = DesktopVaultsRules.ordered(vaults).map { vault ->
            var v = vault
            if (npubOf(v)?.let { removedKeyForMesh(it) in gone } == true) v = v.copy(meshNpub = null)
            if (v.hostKey?.let { removedKeyForHost(it) in gone } == true) v = v.copy(httpsURL = null)
            v
        }.filter { it.meshNpub != null || it.httpsURL != null }
        return DesktopVaultsRules.ordered(out)
    }

    // ── Rule 8: a bare IP address is never listed ──

    /**
     * True when [url]'s host is a literal IPv4 or IPv6 address. Such a Vault still syncs over it, but none of its list
     * switches may turn on: the address would be public (Tron S2; a private-range check doesn't catch a WAN address).
     */
    fun isIPHost(url: String): Boolean {
        var host = DesktopVaultsRules.base(url).lowercase()
        host.indexOf('/').let { if (it >= 0) host = host.substring(0, it) }
        if (host.startsWith("[")) return true
        // More than one colon and no brackets: a bare IPv6 address.
        if (host.count { it == ':' } > 1) return true
        host.indexOf(':').let { if (it >= 0) host = host.substring(0, it) }
        host = host.trimEnd('.')
        val parts = host.split(".")
        return parts.size == 4 && parts.all { part ->
            part.isNotEmpty() && part.length <= 3 && part.all(Char::isDigit) && part.toInt() <= 255
        }
    }

    const val IP_HOST_MESSAGE = "Use a domain name; a bare IP address would be public."

    // ── Add ──

    sealed class AddRefusal {
        object NoAddress : AddRefusal()
        object NotWebAddress : AddRefusal()
        object NotMeshAddress : AddRefusal()
        object OwnAddress : AddRefusal()
        data class HostTaken(val vault: DesktopVault) : AddRefusal()
        data class MeshTaken(val vault: DesktopVault) : AddRefusal()

        val message: String
            get() = when (this) {
                NoAddress -> "Pair it over the Mesh, type its web address, or both."
                NotWebAddress -> "That isn't a web address. Type it like https://vault.example.com"
                NotMeshAddress -> "That isn't a mesh address."
                OwnAddress -> "That is this device's own address."
                is HostTaken -> DesktopVaultsLists.hostTakenMessage(vault)
                is MeshTaken -> "That device is already your Vault ${vault.displayName}."
            }
    }

    /** A Vault, or why not. */
    sealed class Added {
        data class Ok(val vault: DesktopVault) : Added()
        data class Refused(val why: AddRefusal) : Added()
    }

    /** A new Vault from the Add sheet: a typed web address, a paired mesh npub, or both. A host or npub another Vault has is refused (rule 4). */
    fun adding(
        name: String, httpsTyped: String, meshNpub: String?, kind: DesktopVaultKind,
        vaults: List<DesktopVault>, ownNpub: String?,
    ): Added {
        val typed = httpsTyped.trim()
        var https: String? = null
        if (typed.isNotEmpty()) {
            val url = DesktopVaultsRules.httpsURL(typed) ?: return Added.Refused(AddRefusal.NotWebAddress)
            DesktopVaultsLists.hostTaken(url, vaults)?.let { return Added.Refused(AddRefusal.HostTaken(it)) }
            https = url
        }
        var npub: String? = null
        val raw = meshNpub?.trim().orEmpty()
        if (raw.isNotEmpty()) {
            val parsed = HomeVaultRules.meshNpubFromInput(raw) ?: return Added.Refused(AddRefusal.NotMeshAddress)
            if (parsed == ownNpub) return Added.Refused(AddRefusal.OwnAddress)
            vaults.firstOrNull { npubOf(it) == parsed }?.let { return Added.Refused(AddRefusal.MeshTaken(it)) }
            npub = parsed
        }
        if (https == null && npub == null) return Added.Refused(AddRefusal.NoAddress)
        val base = npub?.let(DesktopVaultsRules::idForMesh)
            ?: DesktopVaultsRules.idForHost(DesktopVaultsLists.hostKey(https!!)!!)
        val order = (vaults.maxOfOrNull { it.order } ?: -1) + 1
        return Added.Ok(DesktopVault(id = freshID(base, vaults), name = name.trim(), kind = kind, meshNpub = npub, httpsURL = https, order = order))
    }

    /**
     * [base], or `base#2`, `base#3`… when another Vault already has it. A Vault keeps its id when its address changes,
     * so a later Vault at the old address would otherwise share it, and Delete or the detail page would pick the wrong
     * one (Tron must-fix 1 on #2511).
     */
    fun freshID(base: String, vaults: List<DesktopVault>): String {
        val taken = vaults.map { it.id }.toSet()
        if (base !in taken) return base
        var n = 2
        while ("$base#$n" in taken) n++
        return "$base#$n"
    }

    /** The Vault list and the removed addresses after an edit. */
    data class Edited(val vaults: List<DesktopVault>, val removed: List<String>)

    /** The list with [vault] added at the end, and [removed] without its addresses: adding an address again undoes an earlier delete. */
    fun inserting(vault: DesktopVault, vaults: List<DesktopVault>, removed: List<String>): Edited {
        val keys = removedKeys(vault).toSet()
        val out = DesktopVaultsRules.ordered(vaults)
        return Edited(out + vault.copy(order = out.size), removed.filterNot { it in keys })
    }

    // ── Change one Vault ──

    sealed class AddressChange {
        data class Ok(val edited: Edited) : AddressChange()
        data class Refused(val why: AddRefusal) : AddressChange()
    }

    /**
     * The Vault's web address changed (or cleared, [typed] empty). The old host goes on `removed`, so the old slot
     * can't come back as a Vault of its own. Refused when another Vault has the new host, or when it would leave the
     * Vault with no address.
     */
    fun changingAddress(id: String, typed: String, vaults: List<DesktopVault>, removed: List<String>): AddressChange {
        val i = vaults.indexOfFirst { it.id == id }
        if (i < 0) return AddressChange.Refused(AddRefusal.NoAddress)
        val trimmed = typed.trim()
        var next: String? = null
        if (trimmed.isNotEmpty()) {
            val url = DesktopVaultsRules.httpsURL(trimmed) ?: return AddressChange.Refused(AddRefusal.NotWebAddress)
            DesktopVaultsLists.hostTaken(url, vaults, except = id)?.let { return AddressChange.Refused(AddRefusal.HostTaken(it)) }
            next = url
        }
        if (next == null && vaults[i].meshNpub == null) return AddressChange.Refused(AddRefusal.NoAddress)
        val gone = removed.toMutableList()
        val nextHost = next?.let(DesktopVaultsLists::hostKey)
        vaults[i].hostKey?.let { old -> if (old != nextHost) gone += removedKeyForHost(old) }
        nextHost?.let { host -> gone.removeAll { it == removedKeyForHost(host) } }
        val out = vaults.toMutableList().also { it[i] = it[i].copy(httpsURL = next) }
        return AddressChange.Ok(Edited(out, gone.distinct()))
    }

    fun renaming(id: String, name: String, vaults: List<DesktopVault>): List<DesktopVault> =
        vaults.map { if (it.id == id) it.copy(name = name.trim()) else it }

    // ── Drag and delete ──

    /** The list after moving the Vault at [from] to position [to] (both in list order), renumbered. */
    fun moving(vaults: List<DesktopVault>, from: Int, to: Int): List<DesktopVault> {
        val out = DesktopVaultsRules.ordered(vaults).toMutableList()
        if (from !in out.indices) return out
        val moved = out.removeAt(from)
        out.add(to.coerceIn(0, out.size), moved)
        return out.mapIndexed { i, vault -> vault.copy(order = i) }
    }

    /** The list without [id], and its addresses on `removed`. */
    fun deleting(id: String, vaults: List<DesktopVault>, removed: List<String>): Edited {
        val vault = vaults.firstOrNull { it.id == id } ?: return Edited(vaults, removed)
        return Edited(DesktopVaultsRules.ordered(vaults.filter { it.id != id }), (removed + removedKeys(vault)).distinct())
    }

    // ── The old slot ──

    /**
     * The one-slot `macRelayURL` while a Vault still has its address, else "". Code that still reads the slot
     * (MAC_RELAY_URL, the old status file, the mesh dial) reads this, so deleting that Vault turns it off too, while
     * `macRelayURL` itself stays as it was for older builds (§3 step 5).
     */
    fun slotInEffect(slot: String, vaults: List<DesktopVault>): String = when (val a = DesktopVaultsRules.SlotAddress.of(slot)) {
        DesktopVaultsRules.SlotAddress.None -> ""
        is DesktopVaultsRules.SlotAddress.Web -> if (vaults.any { it.hostKey == a.host }) slot else ""
        is DesktopVaultsRules.SlotAddress.Mesh -> if (vaults.any { npubOf(it) == a.npub }) slot else ""
    }

    // ── Rows on Relays, DM inbox and Media Servers (§2.4) ──

    /** One Vault entry of a published list, shown read only as "From your Vault <name>". */
    data class ListedEntry(val vault: DesktopVault, val url: String, val mesh: Boolean) {
        val id: String get() = "${vault.id}|$url"
    }

    /** The Vault entries of [tags], in list order. */
    fun listedEntries(tags: List<List<String>>, list: DesktopVaultList, vaults: List<DesktopVault>): List<ListedEntry> =
        tags.mapNotNull { tag ->
            if (tag.size < 2) return@mapNotNull null
            val vault = DesktopVaultsLists.owner(tag, list, vaults) ?: return@mapNotNull null
            ListedEntry(vault, tag[1], DesktopVaultsLists.meshNpub(tag, list) != null)
        }

    /**
     * [tags] split into the Vault entries (as published, in place) and the rest. A Relays save keeps the first part as
     * it is: only a Vault's switch adds or removes its entries (§2.4, Tron M2).
     */
    fun splitting(tags: List<List<String>>, list: DesktopVaultList, vaults: List<DesktopVault>): Pair<List<List<String>>, List<List<String>>> =
        tags.partition { it.size >= 2 && DesktopVaultsLists.owner(it, list, vaults) != null }
}
