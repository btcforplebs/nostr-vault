package com.nostrvault.service

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject

/** One version of a list as the vault keeps it (haven-go list_history.go). Twin of iOS `ListVersion`. */
data class ListVersion(
    val id: String,
    val pubkey: String,
    val kind: Int,
    val createdAt: Long,
    val tags: List<List<String>>,
    val content: String,
) {
    /** The `d` tag of an addressable list (kinds 30000-39999), else "". */
    val d: String
        get() = if (kind in 30000..39999) tags.firstOrNull { it.size >= 2 && it[0] == "d" }?.get(1).orEmpty() else ""

    companion object {
        fun of(event: NostrEvent) = ListVersion(event.id, event.pubkey, event.kind, event.createdAt, event.tags, event.content)
    }
}

/**
 * Which lists the vault keeps old versions of, and when a new version looks
 * like a wipe. Twin of haven-go `list_shrink.go` and iOS `ListShrinkRule.swift`:
 * the kind set and the rule must stay the same in all three
 * (RESEARCH/NV_LIST_PROTECTION_PLAN.md, Logen 2026-11-02).
 */
object ListShrinkRule {
    /** Kind 0 is not a list but is kept the same way; its items are the profile's filled-in fields. */
    val protectedKinds: List<Int> = listOf(
        0, 3, 10000, 10001, 10002, 10003, 10004, 10006, 10007,
        10015, 10030, 10050, 10063, 30000, 30002, 30003, 30030,
    )

    /** Lists with an encrypted private part the vault can't read: a large drop in content length counts too. */
    val encryptedKinds: Set<Int> = setOf(10000, 10003, 30000, 30003)

    /** Tags naming or describing a list rather than being an item in it. */
    val metadataTags: Set<String> = setOf("d", "title", "name", "description", "image", "alt", "client")

    /** A list this size or larger is a wipe when it loses more than half. */
    const val MIN_ITEMS = 10

    /** The same for an encrypted part, in characters of content. */
    const val MIN_CONTENT = 1000

    fun isProtected(kind: Int) = kind in protectedKinds

    /** What the person calls the list. */
    fun name(kind: Int): String = when (kind) {
        0 -> "profile"
        3 -> "follows"
        10000 -> "mutes"
        10001 -> "pinned notes"
        10002 -> "relay list"
        10003 -> "bookmarks"
        10004 -> "communities"
        10006 -> "blocked relays"
        10007 -> "search relays"
        10015 -> "interests"
        10030 -> "emoji list"
        10050 -> "DM relays"
        10063 -> "media servers"
        30000 -> "follow set"
        30002 -> "relay set"
        30003 -> "bookmark set"
        30030 -> "emoji set"
        else -> "list $kind"
    }

    /** The public items of a list by (name, value), or a profile's filled-in fields by (field, value). */
    fun items(v: ListVersion): Set<String> {
        if (v.kind == 0) {
            val fields = runCatching { Json.parseToJsonElement(v.content).jsonObject }.getOrNull() ?: return emptySet()
            return fields.mapNotNullTo(mutableSetOf()) { (key, value) ->
                when {
                    value is JsonNull -> null
                    value is JsonPrimitive && value.isString -> value.content.takeIf { it.isNotEmpty() }?.let { "$key\u0000$it" }
                    value is JsonPrimitive -> "$key\u0000${value.content}"
                    value is JsonObject -> "$key\u0000$value"
                    else -> "$key\u0000$value"
                }
            }
        }
        return v.tags.mapNotNullTo(mutableSetOf()) { tag ->
            val name = tag.firstOrNull() ?: return@mapNotNullTo null
            if (name in metadataTags) null else if (tag.size > 1) "$name\u0000${tag[1]}" else name
        }
    }

    /** How many items: every tag but the metadata ones (one per tag, as the vault counts), or a profile's filled-in fields. */
    fun itemCount(v: ListVersion): Int =
        if (v.kind == 0) items(v).size else v.tags.count { tag -> tag.firstOrNull()?.let { it !in metadataTags } ?: false }

    /**
     * Whether [next], the version after [prev], looks like a wipe rather than
     * an edit: empty where [prev] was not, or under half of a list of
     * [MIN_ITEMS] or more. For an encrypted list the content counts the same way, by length.
     */
    fun shrank(prev: ListVersion, next: ListVersion): Boolean {
        val old = itemCount(prev)
        val new = itemCount(next)
        if (old > 0 && new == 0) return true
        if (old >= MIN_ITEMS && new * 2 < old) return true
        if (prev.kind in encryptedKinds) {
            val oldLen = prev.content.length
            val newLen = next.content.length
            if (oldLen > 0 && newLen == 0) return true
            if (oldLen >= MIN_CONTENT && newLen * 2 < oldLen) return true
        }
        return false
    }

    /** Whether [v] still holds everything in [than]: every public item and, for an encrypted list, at least as long a content. */
    fun holds(v: ListVersion, than: ListVersion): Boolean {
        if (!items(v).containsAll(items(than))) return false
        if (than.kind in encryptedKinds && v.content.length < than.content.length) return false
        return true
    }
}
