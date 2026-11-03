package com.nostrvault.shareportal

import android.content.Context
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import java.io.File

/**
 * The accounts the share sheet may "post as": npub, display name and picture
 * URL only — no key, no signer kind. Written by the app
 * ([com.nostrvault.service.shareportal.ShareAccountsPublisher]), read by the
 * share sheet, so the sheet never opens the config that holds the keys.
 * Mirrors NVShareAccountsSnapshot.swift; contract §4.
 */
data class ShareAccountsSnapshot(
    val active: String,
    val accounts: List<Account>,
) {
    data class Account(val npub: String, val name: String, val picture: String? = null)

    fun encode(): String = Json.encodeToString(JsonObject.serializer(), buildJsonObject {
        put("v", VERSION)
        put("active", active)
        put("accounts", buildJsonArray {
            accounts.forEach { a ->
                add(buildJsonObject {
                    put("npub", a.npub); put("name", a.name); a.picture?.let { put("picture", it) }
                })
            }
        })
    })

    companion object {
        const val VERSION = 1
        private const val MAX_ACCOUNTS = 50
        private const val MAX_NAME = 100
        private const val MAX_PICTURE = 2_048

        fun decode(raw: String): ShareAccountsSnapshot? {
            val o = runCatching { Json.parseToJsonElement(raw) }.getOrNull() as? JsonObject ?: return null
            if ((o["v"] as? JsonPrimitive)?.longOrNull != VERSION.toLong()) return null
            val active = (o["active"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return null
            val list = (o["accounts"] as? JsonArray)?.take(MAX_ACCOUNTS)?.mapNotNull { e ->
                val a = e as? JsonObject ?: return@mapNotNull null
                val npub = (a["npub"] as? JsonPrimitive)?.takeIf { it.isString }?.content
                    ?.takeIf { it.startsWith("npub1") } ?: return@mapNotNull null
                val name = (a["name"] as? JsonPrimitive)?.takeIf { it.isString }?.content.orEmpty()
                val picture = (a["picture"] as? JsonPrimitive)?.takeIf { it.isString }?.content
                Account(npub, ShareIntent.cap(name, MAX_NAME), picture?.let { ShareIntent.cap(it, MAX_PICTURE) })
            } ?: return null
            return ShareAccountsSnapshot(active, list)
        }

        fun file(context: Context): File = File(context.filesDir, "share_portal/accounts.json")

        fun read(file: File): ShareAccountsSnapshot? =
            runCatching { file.readText() }.getOrNull()?.let(::decode)

        /** Atomic: written to a temp name and renamed, so the sheet never reads half a file. */
        fun write(file: File, snapshot: ShareAccountsSnapshot): Boolean = runCatching {
            file.parentFile?.mkdirs()
            val tmp = File(file.parentFile, ".${file.name}.tmp")
            tmp.writeText(snapshot.encode())
            tmp.renameTo(file)
        }.getOrDefault(false)
    }
}
