package com.nostrvault.service

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray

/**
 * NIP-51 bookmarks (kind 10003): `e` tags for notes and `a` tags for articles
 * and other addressable events, public in the tags and private in the
 * encrypted content. A bookmark tap changes one entry and keeps every other
 * tag as it is (Logen 2026-11-02, plan db0353a6). Twin of iOS `BookmarkList.swift`.
 */
object BookmarkList {
    const val KIND = 10003

    sealed interface Entry {
        val tag: List<String>

        /** A note by event id (lowercase hex). */
        data class Event(val id: String) : Entry {
            override val tag: List<String> get() = listOf("e", id)
        }

        /** An addressable event by "kind:pubkey:d". */
        data class Address(val coordinate: String) : Entry {
            override val tag: List<String> get() = listOf("a", coordinate)

            /** The coordinate's parts, for fetching it; a d may hold colons. */
            val parts: Triple<Int, String, String>?
                get() {
                    val p = coordinate.split(":", limit = 3)
                    val kind = p.getOrNull(0)?.toIntOrNull() ?: return null
                    return if (p.size == 3) Triple(kind, p[1], p[2]) else null
                }
        }
    }

    /** How a publish went: the new list, the list already said so, or nothing was published ([why], if known). */
    sealed interface Publish {
        data class Saved(val event: NostrEvent) : Publish
        data class Unchanged(val base: NostrEvent?) : Publish
        data class Failed(val why: String?) : Publish
    }

    /** The entry for an event: its address when it is addressable (30000-39999), else its id. */
    fun entry(id: String, pubkey: String, kind: Int, tags: List<List<String>>): Entry {
        if (kind in 30000..39999) {
            val d = tags.firstOrNull { it.size >= 2 && it[0] == "d" }?.get(1).orEmpty()
            return Entry.Address("$kind:${pubkey.lowercase()}:$d")
        }
        return Entry.Event(id.lowercase())
    }

    /** The `e` or `a` tag as an entry; null for any other tag. */
    fun entry(tag: List<String>): Entry? {
        if (tag.size < 2 || tag[1].isEmpty()) return null
        return when (tag[0]) {
            "e" -> Entry.Event(tag[1].lowercase())
            "a" -> Entry.Address(tag[1])
            else -> null
        }
    }

    /** The bookmarks in [tags], newest first (NIP-51 appends new entries at the end), each once. */
    fun entries(tags: List<List<String>>): List<Entry> = tags.asReversed().mapNotNull(::entry).distinct()

    fun contains(tags: List<List<String>>, entry: Entry): Boolean = tags.any { entry(it) == entry }

    /**
     * [tags] with [entry] added at the end ([on]) or every copy of it taken out. Every other tag, unknown ones
     * included, stays where it was, and adding one already there changes nothing.
     */
    fun toggled(tags: List<List<String>>, entry: Entry, on: Boolean): List<List<String>> =
        if (on) { if (contains(tags, entry)) tags else tags + listOf(entry.tag) } else tags.filter { entry(it) != entry }

    /**
     * What a note's bookmark item offers. A note only in the private part shows as bookmarked privately and
     * offers nothing: a tap would add it to the public tags, making a private bookmark visible to everyone
     * (Logen 2026-11-02, cd729657). Public wins when it is in both. iOS `BookmarkList.MenuState`.
     */
    enum class MenuState { ADD, REMOVE, PRIVATELY }

    fun menuState(publicTags: List<List<String>>, privateEntries: Set<Entry>, entry: Entry): MenuState = when {
        contains(publicTags, entry) -> MenuState.REMOVE
        entry in privateEntries -> MenuState.PRIVATELY
        else -> MenuState.ADD
    }

    /** The private bookmarks: the decrypted content, a JSON array of tags. Empty when it is anything else. */
    fun privateEntries(plaintext: String): List<Entry> {
        val array = runCatching { Json.parseToJsonElement(plaintext).jsonArray }.getOrNull() ?: return emptyList()
        val tags = array.mapNotNull { el ->
            (el as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }
        }
        return entries(tags)
    }
}
