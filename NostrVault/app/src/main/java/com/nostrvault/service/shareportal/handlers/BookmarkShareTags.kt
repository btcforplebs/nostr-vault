package com.nostrvault.service.shareportal.handlers

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.add

/**
 * Save for later: a shared web link as a NIP-51 bookmark (kind 10003, `r` tag), public in the tags or private in the
 * content (a JSON array of tags, NIP-44 encrypted to the account itself). Pure and fixture-tested
 * (bookmark-cases.json); mirrors BookmarkShareTags.swift. It only edits the list the Bookmarks store's merged-list path
 * fetched: every other tag, and every other private entry, goes back as it was.
 */
object BookmarkShareTags {
    const val KIND = 10003

    sealed interface Change {
        /** Already on the list: nothing to sign. */
        data object AlreadyPublic : Change
        data object AlreadyPrivate : Change
        data class PublicTags(val tags: List<List<String>>) : Change
        data class PrivateTags(val tags: List<List<String>>) : Change
    }

    /** The link a share saves: the page's http(s) address, trimmed; null when the share named none. */
    fun url(raw: String?): String? {
        val s = raw?.trim().orEmpty()
        if (s.isEmpty()) return null
        val lower = s.lowercase()
        return s.takeIf { (lower.startsWith("https://") || lower.startsWith("http://")) && s.length > 8 }
    }

    fun has(tags: List<List<String>>, url: String): Boolean = tags.any { it.size >= 2 && it[0] == "r" && it[1].trim() == url }

    /** Adds [url] publicly or privately. A link already saved either way is left alone: saving it publicly would show
     *  a private bookmark to everyone. */
    fun adding(url: String, publicTags: List<List<String>>, privateTags: List<List<String>>, privately: Boolean): Change = when {
        has(privateTags, url) -> Change.AlreadyPrivate
        has(publicTags, url) -> Change.AlreadyPublic
        privately -> Change.PrivateTags(privateTags + listOf(listOf("r", url)))
        else -> Change.PublicTags(publicTags + listOf(listOf("r", url)))
    }

    /** The private part's tags: null when it isn't a JSON array of string arrays, so a part this device can't read is
     *  never written over. An empty or blank part is no private entries. */
    fun privateTags(plaintext: String): List<List<String>>? {
        if (plaintext.isBlank()) return emptyList()
        val array = runCatching { Json.parseToJsonElement(plaintext) }.getOrNull() as? JsonArray ?: return null
        return array.map { entry ->
            val tag = entry as? JsonArray ?: return null
            tag.map { v -> (v as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return null }
        }
    }

    /** Whether a private part is sealed again with NIP-04: when the list's part already is (an `?iv=` in it), as the
     *  mute list path keeps it, so an app that only reads NIP-04 still sees it. Otherwise NIP-44. */
    fun sealsAsNip04(existingContent: String): Boolean = existingContent.contains("?iv=")

    fun json(tags: List<List<String>>): String = buildJsonArray {
        for (t in tags) add(buildJsonArray { for (v in t) add(v) })
    }.toString()
}
