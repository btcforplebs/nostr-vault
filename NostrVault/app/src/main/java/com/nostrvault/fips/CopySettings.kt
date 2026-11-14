package com.nostrvault.fips

import com.nostrvault.relay.HavenConfig
import com.nostrvault.ui.screens.settings.RelayAccessLimits
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull

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

    enum class Type { BOOL, INT, STRINGS, OBJECT_STRING, OBJECT_BOOL }

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
    )
    val WOT_DEPTH_RANGE = 0..3

    private val SECRET_MARKERS = listOf("nsec1", "ncryptsec1", "nostr+walletconnect:", "bunker:")
    private val HEX_RUN = Regex("[0-9a-fA-F]{64,}")

    // ---- Export (this app's config → the contract keys) ----

    /** The allowlisted keys for [c]. A home vault or a Mac on the mesh (`.fips`) is this device's own, never sent. */
    fun keys(c: HavenConfig): JsonObject = JsonObject(
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
        ),
    )

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
    fun apply(c: HavenConfig, keys: JsonObject): HavenConfig {
        var out = c
        keys["feed_layouts"]?.let { el -> out = out.copy(feedLayoutModes = cleanLayouts((el as JsonObject).mapValues { (it.value as JsonPrimitive).content })) }
        bool(keys, "zaps_only")?.let { out = out.copy(zapsOnlyMode = it) }
        bool(keys, "auto_load_new_posts")?.let { out = out.copy(autoLoadNewPosts = it) }
        bool(keys, "new_posts_pill")?.let { out = out.copy(showNewPostsPill = it) }
        (keys["wot_depth"] as? JsonPrimitive)?.longOrNull?.let {
            out = out.copy(chatRelayWotDepth = RelayAccessLimits.clampedFollowDistance(it.toInt()))
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
    }
}
