package com.nostrvault.fips

import com.nostrvault.relay.DesktopVault
import com.nostrvault.relay.DesktopVaultKind
import com.nostrvault.relay.DesktopVaultsRules
import com.nostrvault.relay.HavenConfig
import com.nostrvault.relay.OwnMeshNpub
import com.nostrvault.relay.desktopVaultsInEffect
import com.nostrvault.ui.screens.settings.RelayAccessLimits
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull
import com.nostrvault.relay.reachFor
import com.nostrvault.relay.withReach

/**
 * The settings that travel with the mesh copy and stay synced after it (docs/MESH_COPY_V2_CONTRACT.md §5,
 * `settings-allowlist.json`, `settings-refuse-cases.json`). Only the allowlisted keys, mapped from this app's own
 * config: never a key, an NWC string, the mesh key, My Devices, the device name or the home vault choice.
 */
object CopySettings {
    const val FILE = "copy-settings.json"
    private const val FUTURE_SLACK_S = 600L

    /** Compact View's layout, retired 11/11. A linked device on an older build may still send it: read and sent as expanded. */
    private const val RETIRED_LAYOUT = "condensed"

    private fun cleanLayouts(layouts: Map<String, String>) =
        layouts.mapValues { if (it.value == RETIRED_LAYOUT) com.nostrvault.data.model.FeedLayoutMode.EXPANDED.storageKey else it.value }

    /** Whether a file still holds the retired layout, so it is written over with the clean one (11/14). */
    fun holdsRetiredLayout(keys: JsonObject): Boolean =
        (keys["feed_layouts"] as? JsonObject)?.values?.any { (it as? JsonPrimitive)?.content == RETIRED_LAYOUT } == true

    enum class Type { BOOL, INT, STRINGS, OBJECT_STRING, OBJECT_BOOL, OBJECT_LIST }

    /** settings-allowlist.json, key for key (a test checks they match). */
    val ALLOWLIST: Map<String, Type> = linkedMapOf(
        "feed_layouts" to Type.OBJECT_STRING,
        "zaps_only" to Type.BOOL,
        "auto_load_new_posts" to Type.BOOL,
        "new_posts_pill" to Type.BOOL,
        "wot_depth" to Type.INT,
        "blocked_relays" to Type.STRINGS,
        "dm_relays" to Type.STRINGS,
        "media_servers" to Type.STRINGS,
        "notifications" to Type.OBJECT_BOOL,
        "desktop_vaults" to Type.OBJECT_LIST,
    )
    val WOT_DEPTH_RANGE = 0..3

    private val SECRET_MARKERS = listOf("nsec1", "ncryptsec1", "nostr+walletconnect:", "bunker:")
    private val HEX_RUN = Regex("[0-9a-fA-F]{64,}")

    // ---- Export (this app's config → the contract keys) ----

    /** The allowlisted keys for [c]. A home vault or a Mac on the mesh (`.fips`) is this device's own, never sent. */
    fun keys(
        c: HavenConfig,
        previousVaults: JsonArray? = null,
        ownNpub: String? = OwnMeshNpub.value,
        nowS: Long = System.currentTimeMillis() / 1000,
    ): JsonObject = JsonObject(
        linkedMapOf(
            "feed_layouts" to JsonObject(cleanLayouts(c.feedLayoutModes).mapValues { JsonPrimitive(it.value) }),
            "zaps_only" to JsonPrimitive(c.zapsOnlyMode),
            "auto_load_new_posts" to JsonPrimitive(c.autoLoadNewPosts),
            "new_posts_pill" to JsonPrimitive(c.showNewPostsPill),
            "wot_depth" to JsonPrimitive(RelayAccessLimits.clampedFollowDistance(c.chatRelayWotDepth)),
            "blocked_relays" to strings(c.blockedRelays),
            "dm_relays" to strings(c.dmRelays),
            "media_servers" to strings(c.blossomMirrors.filterNot(::onMesh)),
            "notifications" to JsonObject(notificationSwitches(c).mapValues { JsonPrimitive(it.value) }),
            "desktop_vaults" to CopyVaults.records(c, previousVaults.entries(), ownNpub, nowS),
        ),
    )

    private fun JsonArray?.entries(): List<JsonObject> = this?.mapNotNull { it as? JsonObject }.orEmpty()

    /** The whole file: `{v:1, updated_at, keys}`. */
    fun file(keys: JsonObject, updatedAt: Long): String =
        JsonObject(linkedMapOf("v" to JsonPrimitive(1), "updated_at" to JsonPrimitive(updatedAt), "keys" to keys)).toString()

    private fun notificationSwitches(c: HavenConfig) = linkedMapOf(
        "mentions" to c.pushNotifyMentions,
        "replies" to c.pushNotifyReplies,
        "dms" to c.pushNotifyDMs,
        "zaps" to c.pushNotifyZaps,
        "reactions" to c.pushNotifyReactions,
        "reposts" to c.pushNotifyReposts,
        "follows" to c.pushNotifyFollows,
    )

    private fun onMesh(url: String): Boolean =
        runCatching { java.net.URI(url).host.orEmpty() }.getOrDefault("").lowercase().endsWith(".fips")

    private fun strings(l: List<String>) = JsonArray(l.map(::JsonPrimitive))

    // ---- Apply (a checked file → this app's config) ----

    /** [c] with every key in [keys] applied; a key not in the file keeps this device's value. */
    fun apply(c: HavenConfig, keys: JsonObject, ownNpub: String? = OwnMeshNpub.value): HavenConfig {
        var out = c
        (keys["desktop_vaults"] as? JsonArray)?.let { out = CopyVaults.apply(out, it.entries(), ownNpub) }
        keys["feed_layouts"]?.let { el -> out = out.copy(feedLayoutModes = cleanLayouts((el as JsonObject).mapValues { (it.value as JsonPrimitive).content })) }
        bool(keys, "zaps_only")?.let { out = out.copy(zapsOnlyMode = it) }
        bool(keys, "auto_load_new_posts")?.let { out = out.copy(autoLoadNewPosts = it) }
        bool(keys, "new_posts_pill")?.let { out = out.copy(showNewPostsPill = it) }
        (keys["wot_depth"] as? JsonPrimitive)?.longOrNull?.let {
            // The file's value is the first account's: the others keep theirs.
            val first = out.reachFor(out.ownerNpub)
            out = out.withReach(first.copy(depth = it.toInt()), out.ownerNpub)
        }
        list(keys, "blocked_relays")?.let { out = out.copy(blockedRelays = it) }
        list(keys, "dm_relays")?.let { out = out.copy(dmRelays = it) }
        // This device's own mesh servers stay: they are never in the file.
        list(keys, "media_servers")?.let { out = out.copy(blossomMirrors = (it + c.blossomMirrors.filter(::onMesh)).distinct()) }
        (keys["notifications"] as? JsonObject)?.let { n ->
            fun on(k: String, now: Boolean) = (n[k] as? JsonPrimitive)?.booleanOrNull ?: now
            out = out.copy(
                pushNotifyMentions = on("mentions", out.pushNotifyMentions),
                pushNotifyReplies = on("replies", out.pushNotifyReplies),
                pushNotifyDMs = on("dms", out.pushNotifyDMs),
                pushNotifyZaps = on("zaps", out.pushNotifyZaps),
                pushNotifyReactions = on("reactions", out.pushNotifyReactions),
                pushNotifyReposts = on("reposts", out.pushNotifyReposts),
                pushNotifyFollows = on("follows", out.pushNotifyFollows),
            )
        }
        return out
    }

    private fun bool(o: JsonObject, k: String) = (o[k] as? JsonPrimitive)?.booleanOrNull
    private fun list(o: JsonObject, k: String) = (o[k] as? JsonArray)?.map { (it as JsonPrimitive).content }

    // ---- The refuse check (the engine's, again on this side before applying) ----

    data class Checked(val updatedAt: Long, val keys: JsonObject)

    /** Why [raw] may not be applied (`bad_version`, `unknown_key`, `bad_type`, `secret_value`), or null. */
    fun refusal(raw: String, nowS: Long): String? = check(raw, nowS).second

    /** The checked file, or null with the refusal. Secrets are looked for first, in the whole file. */
    fun check(raw: String, nowS: Long): Pair<Checked?, String?> {
        val whole = runCatching { Json.parseToJsonElement(raw) }.getOrNull() ?: return null to "bad_version"
        if (secretAnywhere(whole)) return null to "secret_value"
        val o = whole as? JsonObject ?: return null to "bad_version"
        val v = (o["v"] as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull
        val at = (o["updated_at"] as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull?.toLong()
        val keys = o["keys"] as? JsonObject
        if (v != 1L || at == null || keys == null || at > nowS + FUTURE_SLACK_S) return null to "bad_version"
        for ((k, value) in keys) {
            val type = ALLOWLIST[k] ?: return null to "unknown_key"
            if (!typeOk(type, value)) return null to "bad_type"
        }
        return Checked(at, keys) to null
    }

    fun secretString(s: String): Boolean {
        val lower = s.lowercase()
        return SECRET_MARKERS.any { it in lower } || HEX_RUN.containsMatchIn(s)
    }

    private fun secretAnywhere(el: JsonElement): Boolean = when (el) {
        is JsonPrimitive -> el.isString && secretString(el.content)
        is JsonArray -> el.any(::secretAnywhere)
        is JsonObject -> el.any { (k, v) -> secretString(k) || secretAnywhere(v) }
    }

    private fun typeOk(t: Type, v: JsonElement): Boolean = when (t) {
        Type.BOOL -> v is JsonPrimitive && !v.isString && v.booleanOrNull != null
        Type.INT -> v is JsonPrimitive && !v.isString && v.doubleOrNull?.let { d ->
            d == Math.floor(d) && d.toLong().toInt() in WOT_DEPTH_RANGE
        } == true
        Type.STRINGS -> v is JsonArray && v.all { it is JsonPrimitive && it.isString }
        Type.OBJECT_STRING -> v is JsonObject && v.values.all { it is JsonPrimitive && it.isString }
        Type.OBJECT_BOOL -> v is JsonObject && v.values.all { it is JsonPrimitive && !it.isString && it.booleanOrNull != null }
        Type.OBJECT_LIST -> CopyVaults.ok(v)
    }
}

/**
 * The Desktop Vault list in the settings copy (`desktop_vaults`, Desktop Vaults P10, plan §2.6, contract §5): each
 * Vault's addresses, name, kind and order, with an `updatedAt` per Vault and tombstones (`id`, `deletedAt`) for
 * deletes, merged per Vault id (`settings-vault-merge-cases.json`). The stamps and tombstones live only in the file:
 * export compares this device's list with the file's to date what changed here. Nothing here reads or writes My
 * Devices, so a copied Vault can never pair (§2.6). iOS twin: the `desktop_vaults` extension in CopySettings.swift.
 */
object CopyVaults {
    const val MAX = 32
    const val TOMB_DAYS = 90L
    val VAULT_FIELDS = mapOf(
        "id" to "string", "name" to "string?", "kind" to "string?", "meshNpub" to "npub?", "httpsURL" to "https?",
        "order" to "int", "updatedAt" to "int",
    )
    val TOMB_FIELDS = mapOf("id" to "string", "deletedAt" to "int")

    private fun JsonObject.str(k: String) = (this[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
    private fun JsonObject.num(k: String) = (this[k] as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull
    private fun JsonObject.long(k: String) = num(k)?.toLong()
    private fun JsonObject.id() = str("id").orEmpty()
    fun isTomb(e: JsonObject) = "deletedAt" in e

    /** A Vault's `updatedAt`, or a tombstone's `deletedAt`. */
    fun stamp(e: JsonObject): Long = e.long("deletedAt") ?: e.long("updatedAt") ?: 0

    /** The field-by-field check of the `object[]` type. */
    fun ok(v: JsonElement): Boolean {
        if (v !is JsonArray) return false
        val seen = mutableSetOf<String>()
        var vaults = 0
        for (x in v) {
            val e = x as? JsonObject ?: return false
            val fields = if (isTomb(e)) TOMB_FIELDS else VAULT_FIELDS.also { vaults++ }
            if (!e.keys.all { it in fields }) return false
            for ((k, t) in fields) {
                val value = e[k] ?: if (t.endsWith("?")) continue else return false
                val str = (value as? JsonPrimitive)?.takeIf { it.isString }?.content
                val good = when (t.removeSuffix("?")) {
                    "string" -> str != null && (k != "id" || str.isNotEmpty())
                    "npub" -> str?.startsWith("npub1") == true
                    "https" -> str?.startsWith("https://") == true
                    else -> e.num(k)?.let { d -> d == Math.floor(d) && d >= (if (k == "order") 0.0 else 1.0) && d < 1e15 } == true
                }
                if (!good) return false
            }
            if (!isTomb(e) && "meshNpub" !in e && "httpsURL" !in e) return false
            if (!seen.add(e.id())) return false
        }
        return vaults <= MAX
    }

    /**
     * Per Vault id, the newer stamp wins; a tie keeps mine, and a tombstone removes a Vault only when newer.
     * Tombstones past 90 days are dropped. Vaults by (order, id), then tombstones by id. The engine's copyVaultsMerge,
     * held to the same fixture.
     */
    fun merge(mine: List<JsonObject>, theirs: List<JsonObject>, nowS: Long): List<JsonObject> {
        val byId = LinkedHashMap<String, JsonObject>()
        for (e in mine) byId[e.id()] = e
        for (t in theirs) {
            val m = byId[t.id()]
            if (m == null || stamp(t) > stamp(m) || (stamp(t) == stamp(m) && isTomb(m) && !isTomb(t))) byId[t.id()] = t
        }
        val oldest = nowS - TOMB_DAYS * 86_400
        val kept = byId.values.filter { !isTomb(it) || stamp(it) >= oldest }
        return kept.filterNot(::isTomb).sortedWith(compareBy({ it.long("order") ?: 0 }, { it.id() })) +
            kept.filter(::isTomb).sortedBy { it.id() }
    }

    private fun record(v: DesktopVault): MutableMap<String, JsonElement> = linkedMapOf<String, JsonElement>(
        "id" to JsonPrimitive(v.id), "name" to JsonPrimitive(v.name), "kind" to JsonPrimitive(v.kind.name.lowercase()),
        "order" to JsonPrimitive(v.order),
    ).also { e ->
        v.meshNpub?.let { e["meshNpub"] = JsonPrimitive(it) }
        v.httpsURL?.let { e["httpsURL"] = JsonPrimitive(it) }
    }

    private fun sameFields(a: JsonObject, b: Map<String, JsonElement>) =
        a.filterKeys { it != "updatedAt" }.mapValues { norm(it.value) } == b.filterKeys { it != "updatedAt" }.mapValues { norm(it.value) }

    /** Numbers compared by value (1767000000 and 1.767E9 alike). */
    private fun norm(e: JsonElement): Any = (e as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull ?: e

    /**
     * This device's Vault list as file entries, dated against [previous] (the file's): an unchanged Vault keeps its
     * stamp, a changed or new one is dated [nowS], and one deleted here becomes a tombstone. Left as the file has it,
     * never deleted: this device's own entry (§2.6), and a mesh address this device isn't paired with, which it can't
     * hold ([DesktopVaultsRules.followingDevices]) and so never removed. Order is kept unless reordered here.
     */
    fun records(c: HavenConfig, previous: List<JsonObject>, ownNpub: String?, nowS: Long): JsonArray {
        val local = DesktopVaultsRules.ordered(c.desktopVaultsInEffect(ownNpub))
        val paired = c.fipsMesh.devices.map { it.npub }.toSet()
        val prevById = previous.associateBy { it.id() }
        fun heldElsewhere(npub: String?) = npub != null && (npub == ownNpub || npub !in paired)
        val prevVaults = previous.filterNot(::isTomb)
        val prevOrder = prevVaults.sortedWith(compareBy({ it.long("order") ?: 0 }, { it.id() })).map { it.id() }
        val localIds = local.map { it.id }
        val reordered = prevOrder.filter { it in localIds } != localIds.filter { it in prevOrder }
        var nextOrder = (prevVaults.mapNotNull { it.long("order") }.maxOrNull() ?: -1) + 1

        val out = mutableListOf<JsonObject>()
        for (v in local) {
            val e = record(v)
            val prev = prevById[v.id]?.takeIf { !isTomb(it) }
            val carried = prev?.str("meshNpub")
            if (v.meshNpub == null && heldElsewhere(carried)) e["meshNpub"] = JsonPrimitive(carried)
            if (!reordered) e["order"] = JsonPrimitive(prev?.long("order") ?: nextOrder++)
            e["updatedAt"] = if (prev != null && sameFields(prev, e)) prev["updatedAt"]!! else JsonPrimitive(nowS)
            out += JsonObject(e)
        }
        for (p in previous) {
            if (p.id() in localIds) continue
            val mesh = p.str("meshNpub")
            out += if (isTomb(p) || heldElsewhere(mesh) && ("httpsURL" !in p || mesh == ownNpub)) p
            else JsonObject(mapOf("id" to JsonPrimitive(p.id()), "deletedAt" to JsonPrimitive(nowS)))
        }
        return JsonArray(merge(out, emptyList(), nowS))
    }

    /**
     * [c] with the file's Vault list taken in, per Vault: a Vault replaces or joins this device's, a tombstone removes
     * it, and this device's own entry is left out. It only ever sets addresses: My Devices is not touched, so a copied
     * Vault pairs nothing.
     */
    fun apply(c: HavenConfig, entries: List<JsonObject>, ownNpub: String?): HavenConfig {
        val tombs = entries.filter(::isTomb).map { it.id() }.toSet()
        val vaults = c.desktopVaultsInEffect(ownNpub).filterNot { it.id in tombs }.toMutableList()
        for (e in entries) {
            if (isTomb(e)) continue
            val mesh = e.str("meshNpub")
            if (ownNpub != null && mesh == ownNpub) continue
            val kind = DesktopVaultKind.entries.firstOrNull { it.name.lowercase() == e.str("kind") } ?: DesktopVaultKind.MAC
            val vault = DesktopVault(
                id = e.id(), name = e.str("name").orEmpty(), kind = kind, meshNpub = mesh, httpsURL = e.str("httpsURL"),
                order = e.long("order")?.toInt() ?: 0,
            )
            val i = vaults.indexOfFirst { it.id == vault.id }
            if (i >= 0) vaults[i] = vault else vaults += vault
        }
        val next = DesktopVaultsRules.ordered(vaults)
        return if (next == c.desktopVaults) c else c.copy(desktopVaults = next)
    }
}
