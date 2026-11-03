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
 * "Send privately" in the share sheet offers the people this account last
 * sent something to *from the share sheet*. Written by the app after a send
 * (DMReviewViewModel), read by the sheet. npub, name and picture URL only: no
 * messages, no follows, no whole contact list. Newest first, at most
 * [MAX_PER_ACCOUNT] per account. Mirrors NVShareContactsSnapshot.swift.
 */
data class ShareContactsSnapshot(
    /** Account npub → its recent recipients, newest first. */
    val recent: Map<String, List<Contact>> = emptyMap(),
) {
    data class Contact(val npub: String, val name: String, val picture: String? = null)

    fun contacts(account: String?): List<Contact> = account?.let { recent[it] }.orEmpty()

    /** [contact] moved to the front of [account]'s list, once, list capped. */
    fun recording(contact: Contact, account: String): ShareContactsSnapshot {
        if (!isNpub(account) || !isNpub(contact.npub)) return this
        val list = listOf(capped(contact)) + recent[account].orEmpty().filter { it.npub != contact.npub }
        return copy(recent = recent + (account to list.take(MAX_PER_ACCOUNT)))
    }

    /** Drops every account not in [keep] (accounts removed from the device). */
    fun keeping(keep: Set<String>): ShareContactsSnapshot = copy(recent = recent.filterKeys { it in keep })

    fun encode(): String = Json.encodeToString(JsonObject.serializer(), buildJsonObject {
        put("v", VERSION)
        put("recent", buildJsonObject {
            recent.forEach { (account, list) ->
                put(account, buildJsonArray {
                    list.forEach { c ->
                        add(buildJsonObject { put("npub", c.npub); put("name", c.name); c.picture?.let { put("picture", it) } })
                    }
                })
            }
        })
    })

    companion object {
        const val VERSION = 1
        const val MAX_PER_ACCOUNT = 8
        private const val MAX_ACCOUNTS = 50
        private const val MAX_NAME = 100
        private const val MAX_PICTURE = 4_096

        private fun isNpub(s: String) = s.startsWith("npub1") && s.length == 63

        private fun capped(c: Contact) =
            Contact(c.npub, ShareIntent.cap(c.name, MAX_NAME), c.picture?.let { ShareIntent.cap(it, MAX_PICTURE) })

        /** Null when not JSON or not version 1. Anything that is not an npub is dropped. */
        fun decode(raw: String): ShareContactsSnapshot? {
            val o = runCatching { Json.parseToJsonElement(raw) }.getOrNull() as? JsonObject ?: return null
            if ((o["v"] as? JsonPrimitive)?.longOrNull != VERSION.toLong()) return null
            val recent = o["recent"] as? JsonObject ?: return ShareContactsSnapshot()
            val clean = LinkedHashMap<String, List<Contact>>()
            for ((account, value) in recent) {
                if (!isNpub(account)) continue
                if (clean.size >= MAX_ACCOUNTS) break
                clean[account] = (value as? JsonArray).orEmpty().mapNotNull { e ->
                    val c = e as? JsonObject ?: return@mapNotNull null
                    val npub = (c["npub"] as? JsonPrimitive)?.takeIf { it.isString }?.content?.takeIf(::isNpub)
                        ?: return@mapNotNull null
                    val name = (c["name"] as? JsonPrimitive)?.takeIf { it.isString }?.content.orEmpty()
                    val picture = (c["picture"] as? JsonPrimitive)?.takeIf { it.isString }?.content
                    capped(Contact(npub, name, picture))
                }.take(MAX_PER_ACCOUNT)
            }
            return ShareContactsSnapshot(clean)
        }

        fun file(context: Context): File = File(context.filesDir, "share_portal/contacts.json")

        fun read(file: File): ShareContactsSnapshot? = runCatching { file.readText() }.getOrNull()?.let(::decode)

        /** Atomic: written to a temp name and renamed. */
        fun write(file: File, snapshot: ShareContactsSnapshot): Boolean = runCatching {
            file.parentFile?.mkdirs()
            val tmp = File(file.parentFile, ".${file.name}.tmp")
            tmp.writeText(snapshot.encode())
            tmp.renameTo(file)
        }.getOrDefault(false)
    }
}
