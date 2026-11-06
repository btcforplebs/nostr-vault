package com.nostrvault.fips

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * The mesh never uses the account key (Logen, 2026-11-06): the copy start and Blossom over the mesh are signed by this
 * device's own mesh key ([MeshKeySigner]), and a vault takes one only from a device in its paired set
 * (docs/MESH_COPY_V2_CONTRACT.md §2, §2.1). The tags here, and the set the engine is given (SetMeshDevicesC), name the
 * receiver's mesh npub, so a token for one vault is refused by another. Pure for the tests.
 * Twin of Apple's `MeshKeyAuth.swift` (#1803).
 */
object MeshKeyAuth {
    /** A mesh 24242 lives at most this long (§2.1: five minutes ahead). */
    const val BLOSSOM_LIFETIME_S = 5 * 60L

    /** The kind of the copy start (NIP-98). */
    const val START_KIND = 27235

    /** The kind of a Blossom token. */
    const val BLOSSOM_KIND = 24242

    enum class Verb(val wire: String) { UPLOAD("upload"), GET("get"), DELETE("delete") }

    /**
     * The kind 27235 for POST <httpBase>/copy/v2/start, signed by B's mesh key: `u`, `method`, and `p` = A's own mesh
     * npub ([receiver]). No `device` tag: A binds the token to the signer. The link's secret path is never signed
     * ([MeshCopyV2.splitLink]). Null without a receiver: A refuses it.
     */
    fun copyStartTags(httpBase: String, receiver: String): List<List<String>>? {
        val p = receiver.trim()
        if (p.isEmpty() || httpBase.isBlank()) return null
        return listOf(
            listOf("u", httpBase.trimEnd('/') + MeshCopyV2.START_PATH),
            listOf("method", "POST"),
            listOf("p", p),
        )
    }

    /**
     * A kind 24242 for one verb over the mesh: one `t`, an `x` for each blob, a `p` for each receiving vault, and an
     * expiration no more than five minutes ahead. Null without a blob or a receiver: the vault refuses both.
     */
    fun blossomTags(
        verb: Verb,
        sha256s: List<String>,
        receivers: List<String>,
        nowS: Long = System.currentTimeMillis() / 1000,
        lifetimeS: Long = BLOSSOM_LIFETIME_S,
        size: Long? = null,
    ): List<List<String>>? {
        val blobs = unique(sha256s.map { it.lowercase() })
        val named = unique(receivers)
        if (blobs.isEmpty() || named.isEmpty()) return null
        val ahead = lifetimeS.coerceIn(1, BLOSSOM_LIFETIME_S)
        return buildList {
            add(listOf("t", verb.wire))
            blobs.forEach { add(listOf("x", it)) }
            size?.let { add(listOf("size", it.toString())) }
            named.forEach { add(listOf("p", it)) }
            add(listOf("expiration", (nowS + ahead).toString()))
        }
    }

    /** One device for the paired set: its mesh npub and role (the engine keeps the role). */
    data class Device(val npub: String, val role: DeviceRole)

    /**
     * The JSON for SetMeshDevicesC: this device's mesh npub and My Devices without it, each once, roles kept. Null when
     * this device has no mesh key yet: the engine then keeps the set it has (none at first, which accepts no device).
     */
    fun deviceSet(selfNpub: String?, devices: List<Device>): String? {
        val own = selfNpub?.trim().orEmpty()
        if (own.isEmpty()) return null
        val seen = mutableSetOf<String>()
        val list = devices.mapNotNull { d ->
            val npub = d.npub.trim()
            if (npub.isEmpty() || npub == own || !seen.add(npub)) null
            else JsonObject(mapOf("npub" to JsonPrimitive(npub), "role" to JsonPrimitive(roleWire(d.role))))
        }
        return JsonObject(mapOf("devices" to JsonArray(list), "self" to JsonPrimitive(own))).toString()
    }

    /** The role as the config and Apple write it. */
    fun roleWire(role: DeviceRole): String = when (role) {
        DeviceRole.MAC -> "mac"
        DeviceRole.PHONE -> "phone"
        DeviceRole.HOME_VAULT -> "home_vault"
        DeviceRole.BROWSER -> "browser"
    }

    /**
     * The header a vault adds to a 401/403 for a Blossom request over the mesh once it has its paired set (haven-go
     * mesh_devices_signal.go, #1804). Its refusal is then final for the device key.
     */
    const val PAIRED_SET_HEADER = "X-Mesh-Devices"

    /**
     * The vault turned the device form down and has no paired set yet (an older build, or a box before havend passes
     * the set): one retry with the owner's form, for as long as vaults accept it. A vault that has its set says so
     * ([PAIRED_SET_HEADER], any case) and gets no account-key token (Tron, #1803). TODO(mesh-key): remove with the
     * owner form.
     */
    fun retriesWithOwnerForm(status: Int, headerNames: Collection<String>): Boolean {
        if (status != 401 && status != 403) return false
        return headerNames.none { it.equals(PAIRED_SET_HEADER, ignoreCase = true) }
    }

    /** [retriesWithOwnerForm] for an OkHttp answer. */
    fun retriesWithOwnerForm(response: okhttp3.Response): Boolean =
        retriesWithOwnerForm(response.code, response.headers.names())

    private fun unique(values: List<String>): List<String> {
        val seen = mutableSetOf<String>()
        return values.map { it.trim() }.filter { it.isNotEmpty() && seen.add(it) }
    }
}
