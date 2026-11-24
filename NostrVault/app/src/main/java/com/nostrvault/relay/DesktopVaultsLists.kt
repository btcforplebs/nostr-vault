package com.nostrvault.relay

import com.nostrvault.fips.HomeVaultRules

/** The owner's three public lists that can name desktop Vaults. iOS DesktopVaultList. */
enum class DesktopVaultList(val kind: Int) {
    /** NIP-65 relays: `["r", "wss://<base>"]`, plus `["fipsmesh", "fipsmesh://<npub>/", "write"]`. */
    RELAYS(10002),
    /** NIP-17 DM inbox: `["relay", "wss://<base>/inbox"]`. No mesh entry is offered. */
    INBOX(10050),
    /** BUD-03 media servers: `["server", "https://<base>"]` and `["server", "fipsmesh://<npub>/"]`. */
    MEDIA(10063);

    /** The message a refused change shows (§2.5 rule 5). */
    val refusal: String
        get() = when (this) {
            RELAYS -> "Add another relay first."
            INBOX -> "Add another DM inbox relay first."
            MEDIA -> "Add another media server first."
        }

    companion object {
        fun ofKind(kind: Int): DesktopVaultList? = entries.firstOrNull { it.kind == kind }
    }
}

/** Which way a Vault is named in a list: its web address or its mesh address. */
enum class DesktopVaultPath { WEB, MESH }

/** The outcome of a Vault switch on one or more lists. */
sealed class DesktopVaultListChange {
    data class Tags(val tags: List<List<String>>) : DesktopVaultListChange()
    /** Nothing may be signed: this list would be left unusable. */
    data class Refused(val list: DesktopVaultList) : DesktopVaultListChange()
}

/**
 * Several Vaults in the public lists (PLANS/NV_DESKTOP_VAULTS_PLAN.md §2.5, rules 1-6). Pure: it works on a list's
 * tags as fetched and returns the tags to sign, so a caller only ever applies one Vault's change to the newest list
 * (rule 7). Fixtures: docs/fixtures/desktop-vaults/lists.json, shared with iOS DesktopVaultsLists and web
 * `box/public-on-web.js`.
 */
object DesktopVaultsLists {

    // ── Rule 1: which entries are a Vault's ──────────────────────

    /**
     * One spelling per web host: scheme, case, path, trailing slash and a default port (`:443`, `:80`) are folded
     * away. Null for a mesh address or anything with no host.
     */
    fun hostKey(raw: String): String? {
        var text = raw.trim().lowercase()
        if (text.startsWith("fipsmesh:")) return null
        for (scheme in listOf("wss://", "ws://", "https://", "http://")) {
            if (text.startsWith(scheme)) {
                text = text.drop(scheme.length)
                break
            }
        }
        val cut = text.indexOfFirst { it == '/' || it == '?' || it == '#' }
        if (cut >= 0) text = text.substring(0, cut)
        for (port in listOf(":443", ":80")) {
            if (text.endsWith(port)) text = text.dropLast(port.length)
        }
        return text.takeIf { it.isNotEmpty() && ' ' !in it }
    }

    /** The tag name each list uses for its entries. */
    fun entryName(list: DesktopVaultList): String = when (list) {
        DesktopVaultList.RELAYS -> "r"
        DesktopVaultList.INBOX -> "relay"
        DesktopVaultList.MEDIA -> "server"
    }

    /** The npub of a mesh entry (a 10002 `fipsmesh` tag or a 10063 mesh `server`), null for any other tag. */
    fun meshNpub(tag: List<String>, list: DesktopVaultList): String? {
        if (tag.size < 2) return null
        val isMeshTag = (list == DesktopVaultList.RELAYS && tag[0] == "fipsmesh") ||
            (list == DesktopVaultList.MEDIA && tag[0] == "server")
        if (!isMeshTag || !tag[1].lowercase().startsWith("fipsmesh:")) return null
        return HomeVaultRules.meshNpubFromInput(tag[1].lowercase())
    }

    /** The host of a web entry, null for a mesh entry or any other tag. */
    fun webHost(tag: List<String>, list: DesktopVaultList): String? {
        if (tag.size < 2 || tag[0] != entryName(list)) return null
        return hostKey(tag[1])
    }

    private fun vaultNpub(vault: DesktopVault): String? = vault.meshNpub?.let(HomeVaultRules::meshNpubFromInput)

    /** The Vault an entry belongs to, if any. Every other entry is the user's own and no Vault switch touches it. */
    fun owner(tag: List<String>, list: DesktopVaultList, vaults: List<DesktopVault>): DesktopVault? {
        meshNpub(tag, list)?.let { npub -> return vaults.firstOrNull { vaultNpub(it) == npub } }
        webHost(tag, list)?.let { host -> return vaults.firstOrNull { it.hostKey == host } }
        return null
    }

    /** Whether [vault]'s switch for [path] reads as on in this list. */
    fun isListed(vault: DesktopVault, path: DesktopVaultPath, list: DesktopVaultList, tags: List<List<String>>): Boolean =
        tags.any { isEntry(it, vault, path, list) }

    fun isEntry(tag: List<String>, vault: DesktopVault, path: DesktopVaultPath, list: DesktopVaultList): Boolean =
        when (path) {
            DesktopVaultPath.WEB -> vault.hostKey?.let { webHost(tag, list) == it } ?: false
            DesktopVaultPath.MESH -> vaultNpub(vault)?.let { meshNpub(tag, list) == it } ?: false
        }

    /**
     * The entry a switch adds, or null when this Vault has no such address or the list takes no such entry (10050
     * has no mesh entry). A web entry carries the whole base, path included: the engine serves `<base>` and
     * `<base>/inbox` (macsync.go), so `wss://host` alone misses a Vault at `/haven` (Tron S2 on #2499).
     */
    fun entry(vault: DesktopVault, path: DesktopVaultPath, list: DesktopVaultList): List<String>? = when (path) {
        DesktopVaultPath.WEB -> {
            val url = vault.httpsURL
            if (url == null || vault.hostKey == null) null else {
                val base = DesktopVaultsRules.base(url)
                when (list) {
                    DesktopVaultList.RELAYS -> listOf("r", "wss://$base")
                    DesktopVaultList.INBOX -> listOf("relay", "wss://$base/inbox")
                    DesktopVaultList.MEDIA -> listOf("server", "https://$base")
                }
            }
        }
        DesktopVaultPath.MESH -> vaultNpub(vault)?.let { npub ->
            when (list) {
                DesktopVaultList.RELAYS -> listOf("fipsmesh", "fipsmesh://$npub/", "write")
                DesktopVaultList.INBOX -> null
                DesktopVaultList.MEDIA -> listOf("server", "fipsmesh://$npub/")
            }
        }
    }

    // ── Rule 2: order ────────────────────────────────────────────

    private val vaultOrder = compareBy<DesktopVault>({ it.order }, { it.id })

    /**
     * Turns [vault]'s switch on. Its entry goes directly after the other Vault entries of the same path, in Desktop
     * Vaults order, and in front of the user's own entries; mesh entries always go last. No existing entry moves.
     * Already listed: the tags come back unchanged.
     */
    fun turningOn(
        vault: DesktopVault, path: DesktopVaultPath, list: DesktopVaultList,
        tags: List<List<String>>, vaults: List<DesktopVault>,
    ): DesktopVaultListChange {
        val entry = entry(vault, path, list) ?: return DesktopVaultListChange.Tags(tags)
        if (isListed(vault, path, list, tags)) return DesktopVaultListChange.Tags(tags)
        val isMesh = { tag: List<String> -> meshNpub(tag, list) != null }
        val firstMesh = tags.indexOfFirst(isMesh).let { if (it < 0) tags.size else it }
        // The other Vaults' entries of this path, with where they sit.
        val placed = tags.indices.mapNotNull { i ->
            if (isMesh(tags[i]) != (path == DesktopVaultPath.MESH)) return@mapNotNull null
            val other = owner(tags[i], list, vaults)?.takeIf { it.id != vault.id } ?: return@mapNotNull null
            i to other
        }
        var index = placed.firstOrNull { vaultOrder.compare(vault, it.second) < 0 }?.first
            ?: placed.lastOrNull()?.let { it.first + 1 }
            ?: if (path == DesktopVaultPath.MESH) tags.size else 0
        // A web entry never lands after a mesh one, even in a list another app left with a Vault entry behind its
        // mesh entries.
        if (path == DesktopVaultPath.WEB) index = minOf(index, firstMesh)
        val out = tags.toMutableList().apply { add(index, entry) }
        // A mesh entry never makes a list usable on its own (NIP-F1 :94).
        if (path == DesktopVaultPath.MESH && !isUsable(out, list)) return DesktopVaultListChange.Refused(list)
        return DesktopVaultListChange.Tags(out)
    }

    /**
     * The tags with the Vault entries put in Desktop Vaults order, in the places Vault entries already hold; the
     * user's own entries stay where they are. Equal to [tags] when nothing would move, so a drag republishes only
     * the lists that change.
     */
    fun reordered(tags: List<List<String>>, list: DesktopVaultList, vaults: List<DesktopVault>): List<List<String>> {
        val out = tags.toMutableList()
        for (mesh in listOf(false, true)) {
            val slots = tags.indices.filter { i ->
                (meshNpub(tags[i], list) != null) == mesh && owner(tags[i], list, vaults) != null
            }
            val sorted = slots.map { tags[it] }.withIndex().sortedWith { a, b ->
                val va = owner(a.value, list, vaults)!!
                val vb = owner(b.value, list, vaults)!!
                if (va.id == vb.id) a.index.compareTo(b.index) else vaultOrder.compare(va, vb)
            }.map { it.value }
            slots.zip(sorted).forEach { (slot, tag) -> out[slot] = tag }
        }
        return out
    }

    // ── Rule 5: removal ──────────────────────────────────────────

    /** Whether a list may be signed: 10002 keeps a wss write relay (a mesh relay doesn't count), 10050 keeps a relay, 10063 keeps an https server. */
    fun isUsable(tags: List<List<String>>, list: DesktopVaultList): Boolean = when (list) {
        DesktopVaultList.RELAYS -> tags.any { tag ->
            tag.size >= 2 && tag[0] == "r" && tag[1].lowercase().startsWith("wss://") && (tag.size < 3 || tag[2] != "read")
        }
        DesktopVaultList.INBOX -> tags.any { it.size >= 2 && it[0] == "relay" && hostKey(it[1]) != null }
        DesktopVaultList.MEDIA -> tags.any { it.size >= 2 && it[0] == "server" && it[1].lowercase().startsWith("https://") }
    }

    /**
     * Turns [vault]'s switch off: takes its entries of [path] out in every spelling and nothing else. Taking only
     * mesh entries off is always allowed; otherwise a list left unusable is refused before signing.
     */
    fun turningOff(vault: DesktopVault, path: DesktopVaultPath, list: DesktopVaultList, tags: List<List<String>>): DesktopVaultListChange {
        val out = tags.filterNot { isEntry(it, vault, path, list) }
        if (out.size == tags.size) return DesktopVaultListChange.Tags(tags)
        if (path == DesktopVaultPath.WEB && !isUsable(out, list)) return DesktopVaultListChange.Refused(list)
        return DesktopVaultListChange.Tags(out)
    }

    /** What deleting a Vault from the public lists gives: only the lists that change, or the list that refused. */
    sealed class Removal {
        data class Changed(val lists: Map<DesktopVaultList, List<List<String>>>) : Removal()
        data class Refused(val list: DesktopVaultList) : Removal()
    }

    /**
     * Deleting a Vault with "Also take <name> out of your public lists?" answered yes: every entry of it in every
     * list, checked for all lists together, so nothing is signed when any one would be left unusable.
     */
    fun removingVault(vault: DesktopVault, lists: Map<DesktopVaultList, List<List<String>>>): Removal {
        val changed = mutableMapOf<DesktopVaultList, List<List<String>>>()
        for (list in DesktopVaultList.entries) {
            val tags = lists[list] ?: continue
            var current = tags
            for (path in listOf(DesktopVaultPath.MESH, DesktopVaultPath.WEB)) {
                when (val change = turningOff(vault, path, list, current)) {
                    is DesktopVaultListChange.Tags -> current = change.tags
                    is DesktopVaultListChange.Refused -> return Removal.Refused(change.list)
                }
            }
            if (current != tags) changed[list] = current
        }
        return Removal.Changed(changed)
    }

    // ── Rule 4: one host, one Vault ──────────────────────────────

    /** The other Vault that already has [httpsURL]'s host, if any: adding or changing to that address is refused. */
    fun hostTaken(httpsURL: String, vaults: List<DesktopVault>, except: String? = null): DesktopVault? {
        val host = hostKey(httpsURL) ?: return null
        return vaults.firstOrNull { it.id != except && it.hostKey == host }
    }

    fun hostTakenMessage(vault: DesktopVault): String = "That address is already your Vault ${vault.displayName}."

    // ── Rule 6: size ─────────────────────────────────────────────

    /** More entries than other apps are told to use (NIP-65: 4 write relays, mesh relays not counted; NIP-17: 3 DM relays). No cap, only a note. */
    fun overGuidance(tags: List<List<String>>, list: DesktopVaultList): Boolean = when (list) {
        DesktopVaultList.RELAYS -> tags.count { tag ->
            tag.size >= 2 && tag[0] == "r" && hostKey(tag[1]) != null && (tag.size < 3 || tag[2] != "read")
        } > 4
        DesktopVaultList.INBOX -> tags.count { it.size >= 2 && it[0] == "relay" } > 3
        DesktopVaultList.MEDIA -> false
    }

    const val OVER_GUIDANCE_NOTE = "Other apps may only use the first few."
}
