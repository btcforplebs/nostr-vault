package com.nostrvault.service.emoji

import com.nostrvault.service.CustomEmoji
import com.nostrvault.service.EmojiListParse
import com.nostrvault.service.EmojiListRepository

/**
 * The rules of the Emoji page's Save copies and zip import (RESEARCH/NV_CUSTOM_EMOJI_PLAN.md §4.1). Pure, for the
 * tests; [EmojiVaultStore] does the network and the vault. Apple twin: `EmojiVaultStore.swift`'s rules.
 */
object EmojiCopyRules {
    /** Per image: bigger is "too big". */
    const val MAX_IMAGE_BYTES = 2L * 1024 * 1024

    /** Per run (a Save copies tap or one zip). */
    const val MAX_FILES = 3_000
    const val MAX_TOTAL_BYTES = 200L * 1024 * 1024

    /** The only types saved: images. */
    val IMAGE_TYPES = setOf("image/png", "image/jpeg", "image/gif", "image/webp", "image/avif")

    /**
     * Public Blossom servers asked for a dead link's file by its hash, after the person's own media servers. A copy
     * from anywhere counts only when its bytes hash to the same value.
     */
    val SEARCH_SERVERS = listOf(
        "https://blossom.primal.net",
        "https://cdn.satellite.earth",
        "https://blossom.band",
        "https://nostr.download",
    )

    /** One emoji to save: every shortcode and set that uses [url]. */
    data class Wanted(val url: String, val codes: List<List<String>>, val sets: List<String>)

    /**
     * What Save copies goes after: one entry per image link across [sets], each with every shortcode and set using it,
     * in set order. Loose emoji (not in a set) are never here (pick 6).
     */
    fun wanted(sets: List<EmojiListRepository.EmojiSet>): List<Wanted> {
        val byUrl = LinkedHashMap<String, Pair<MutableList<List<String>>, MutableList<String>>>()
        for (set in sets) for (e in set.emojis) {
            if (!CustomEmoji.isValidShortcode(e.shortcode) || !CustomEmoji.isValidURL(e.url)) continue
            val (codes, addrs) = byUrl.getOrPut(e.url) { mutableListOf<List<String>>() to mutableListOf() }
            listOf(e.shortcode, e.url).let { if (it !in codes) codes += it }
            if (set.address !in addrs) addrs += set.address
        }
        return byUrl.map { (url, v) -> Wanted(url, v.first, v.second) }
    }

    /** The 64-hex hash a Blossom-style link carries in its last path part (`…/<sha>.png`), or null. */
    fun hashInUrl(url: String): String? {
        val path = runCatching { java.net.URI(url).rawPath }.getOrNull() ?: return null
        val last = path.substringAfterLast('/').substringBefore('.').lowercase()
        return last.takeIf { it.length == 64 && it.all { c -> c in '0'..'9' || c in 'a'..'f' } }
    }

    /**
     * Where else to look for a dead link: `<server>/<sha>` on [ownServers] then [SEARCH_SERVERS], each once, never the
     * dead link's own host. Empty when the link carries no hash (nothing to check a copy against).
     */
    fun searchUrls(url: String, ownServers: List<String>): List<String> {
        val sha = hashInUrl(url) ?: return emptyList()
        val host = runCatching { java.net.URI(url).host?.lowercase() }.getOrNull()
        return (ownServers + SEARCH_SERVERS)
            .map { it.trim().trimEnd('/') }
            .filter { it.lowercase().startsWith("https://") }
            .filter { runCatching { java.net.URI(it).host?.lowercase() }.getOrNull() != host }
            .distinct()
            .map { "$it/$sha" }
    }

    /** Whether a download of [size] bytes and [mime] may be saved: an image, at most [MAX_IMAGE_BYTES]. */
    fun refusal(mime: String, size: Long): Skip? = when {
        mime.lowercase().substringBefore(';').trim() !in IMAGE_TYPES -> Skip.NOT_IMAGE
        size > MAX_IMAGE_BYTES -> Skip.TOO_BIG
        else -> null
    }

    enum class Skip { NOT_IMAGE, TOO_BIG, DEAD, OVER_CAP, NO_MATCH, NOT_STORED }

    /** A run's tally, for the line under the button ("Saved 203 · 9 dead · 4 too big"). */
    data class Tally(
        val saved: Int = 0,
        val already: Int = 0,
        val dead: Int = 0,
        val tooBig: Int = 0,
        val notImage: Int = 0,
        val overCap: Int = 0,
        val noMatch: Int = 0,
        /** The vault refused or failed the store (full disk, signer). */
        val notStored: Int = 0,
        val bytes: Long = 0,
    ) {
        fun capReached(nextBytes: Long): Boolean = saved >= MAX_FILES || bytes + nextBytes > MAX_TOTAL_BYTES

        fun line(): String = listOfNotNull(
            "Saved $saved",
            already.takeIf { it > 0 }?.let { "$it already saved" },
            dead.takeIf { it > 0 }?.let { "$it dead" },
            tooBig.takeIf { it > 0 }?.let { "$it too big" },
            notImage.takeIf { it > 0 }?.let { "$it not images" },
            overCap.takeIf { it > 0 }?.let { "$it over the limit" },
            noMatch.takeIf { it > 0 }?.let { "$it matched no set" },
            notStored.takeIf { it > 0 }?.let { "$it not stored by your vault" },
        ).joinToString(" · ")

        fun skip(why: Skip): Tally = when (why) {
            Skip.NOT_IMAGE -> copy(notImage = notImage + 1)
            Skip.TOO_BIG -> copy(tooBig = tooBig + 1)
            Skip.DEAD -> copy(dead = dead + 1)
            Skip.OVER_CAP -> copy(overCap = overCap + 1)
            Skip.NO_MATCH -> copy(noMatch = noMatch + 1)
            Skip.NOT_STORED -> copy(notStored = notStored + 1)
        }
    }

    /**
     * The emoji a zip file matches in the saved [sets]: by the file's [sha256] = the hash in an emoji's link, or by
     * file name = shortcode (folders and extension dropped). A name match never overrides a hash: a link that carries
     * a hash matches only bytes that hash to it. A name used by more than one image link (`:smile:` in two sets) is
     * ambiguous and matches nothing, so one file never becomes the image for two different links. The result's codes
     * name every link the file now stands for. Null: the file matches no set, so it is skipped (pick 6).
     */
    fun zipMatch(fileName: String, sha256: String, sets: List<EmojiListRepository.EmojiSet>): Wanted? {
        val base = fileName.substringAfterLast('/').substringBeforeLast('.')
        val sha = sha256.lowercase()
        val all = wanted(sets)
        val byHash = all.filter { hashInUrl(it.url) == sha }
        val byName = all.filter { w -> hashInUrl(w.url) == null && w.codes.any { it[0] == base } }
        val hits = byHash + byName.takeIf { it.size == 1 }.orEmpty()
        if (hits.isEmpty()) return null
        return Wanted(
            hits.first().url,
            hits.flatMap { it.codes }.distinct(),
            hits.flatMap { it.sets }.distinct(),
        )
    }

    /** Whether a zip entry is worth reading: an image by its name, no folder tricks, no hidden file. */
    fun zipEntryLooksLikeImage(name: String): Boolean {
        if (name.contains("..") || name.startsWith("/")) return false
        val file = name.substringAfterLast('/')
        if (file.startsWith(".") || file.isEmpty()) return false
        return file.substringAfterLast('.', "").lowercase() in setOf("png", "jpg", "jpeg", "gif", "webp", "avif")
    }

    /**
     * A 10030's tags with [address] added (at the end) or removed. Every other tag stays as it was: loose emoji,
     * other sets, anything another app wrote (the list merge rule). Null when there is nothing to change.
     */
    fun listTags(current: List<List<String>>, address: String, add: Boolean): List<List<String>>? {
        if (EmojiListParse.setRef(address) == null) return null
        val has = current.any { it.size >= 2 && it[0] == "a" && it[1] == address }
        return when {
            add && has -> null
            add -> current + listOf(listOf("a", address))
            !has -> null
            else -> current.filterNot { it.size >= 2 && it[0] == "a" && it[1] == address }
        }
    }
}
