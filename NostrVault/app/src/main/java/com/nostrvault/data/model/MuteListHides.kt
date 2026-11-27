package com.nostrvault.data.model

import com.nostrvault.relay.HavenConfig

/**
 * What a NIP-51 kind 10000 hides beyond people: muted words (`word`),
 * hashtags (`t`) and threads (`e`). Other clients (Amethyst, Primal) write
 * them, in the public tags or the encrypted private part. Apple:
 * HavenApp/Models/MuteList.swift; web: web-vault/src/net/blocks.js.
 *
 * Kept per account in [HavenConfig.mutedPerAccount] (public) and
 * [HavenConfig.privateMutedPerAccount] (private), apart like the people, so
 * an edit here never moves a private entry into the public tags.
 */
@kotlinx.serialization.Serializable
data class MutedThings(
    /** Lowercased words or phrases. */
    val words: List<String> = emptyList(),
    /** Lowercased, without the "#". */
    val hashtags: List<String> = emptyList(),
    /** Lowercased hex event ids: the note itself, and every reply under it. */
    val threads: List<String> = emptyList(),
) {
    val isEmpty: Boolean get() = words.isEmpty() && hashtags.isEmpty() && threads.isEmpty()

    operator fun plus(other: MutedThings) = MutedThings(
        (words + other.words).distinct(),
        (hashtags + other.hashtags).distinct(),
        (threads + other.threads).distinct(),
    )

    companion object {
        val EMPTY = MutedThings()
        private val HEX64 = Regex("^[0-9a-f]{64}$")

        /** The `word`, `t` and `e` entries of [tags], trimmed, lowercased and deduped. */
        fun from(tags: List<List<String>>): MutedThings {
            fun values(name: String) = tags.asSequence()
                .filter { it.size >= 2 && it[0] == name }
                .map { it[1].trim().lowercase() }
                .filter { it.isNotEmpty() }
            return MutedThings(
                words = values("word").distinct().toList(),
                hashtags = values("t").map { it.removePrefix("#") }.filter { it.isNotEmpty() }.distinct().toList(),
                threads = values("e").filter { HEX64.matches(it) }.distinct().toList(),
            )
        }
    }
}

/**
 * The one check every surface asks: does this account's mute list hide a
 * note? People are checked by the block list the screens already use.
 * Words match whole words or phrases, case-insensitively, on Unicode letter
 * and digit boundaries (Logen 2026-11-27): "ass" hides "ass!" but not "class".
 */
class MuteRules(things: MutedThings) {
    private val words = things.words.filter { it.isNotEmpty() }.map(::wordPattern)
    private val hashtags = things.hashtags.toSet()
    private val threads = things.threads.toSet()

    val isEmpty: Boolean get() = words.isEmpty() && hashtags.isEmpty() && threads.isEmpty()

    /**
     * Whether a note is hidden by a muted word, hashtag or thread: [id] or
     * [parentId] is a muted thread, as is its NIP-10 root or reply target
     * (mention-marked `e` tags are quotes, not the thread); a `t` tag is a
     * muted hashtag; or [content] holds a muted word.
     */
    fun hides(id: String, content: String, tags: List<List<String>>, parentId: String? = null): Boolean {
        if (isEmpty) return false
        if (threads.isNotEmpty()) {
            if (id.lowercase() in threads) return true
            if (parentId != null && parentId.lowercase() in threads) return true
            if (tags.any { it.size >= 2 && it[0] == "e" && (it.size < 4 || it[3] != "mention") && it[1].lowercase() in threads }) return true
        }
        if (hashtags.isNotEmpty() && tags.any { it.size >= 2 && it[0] == "t" && it[1].lowercase().removePrefix("#") in hashtags }) return true
        return hidesText(content)
    }

    /** Whether [text] holds a muted word: a DM, a notification preview. */
    fun hidesText(text: String): Boolean {
        if (words.isEmpty() || text.isEmpty()) return false
        return words.any { it.containsMatchIn(text) }
    }

    /** [note] as it shows: its text, tags, id and the post it answers or reposts. */
    fun hides(note: FeedNote): Boolean =
        hides(note.id, note.content, note.tags, note.parentEventId) ||
            (note.repostedEventId != null && note.repostedEventId.lowercase() in threads)

    companion object {
        val NONE = MuteRules(MutedThings.EMPTY)

        /** [word] alone: no letter or digit right before or after it. */
        fun wordPattern(word: String): Regex =
            Regex("(?<![\\p{L}\\p{N}])" + Regex.escape(word) + "(?![\\p{L}\\p{N}])", setOf(RegexOption.IGNORE_CASE))
    }
}

/** [npub]'s muted words, hashtags and threads, public and private together. */
fun HavenConfig.mutedFor(npub: String): MutedThings =
    mutedPerAccount[npub].orEmpty() + privateMutedPerAccount[npub].orEmpty()

private fun MutedThings?.orEmpty(): MutedThings = this ?: MutedThings.EMPTY

/**
 * The rules for [npub], built once per distinct list: the feed asks on every
 * recompute and building compiles a regex per word.
 */
fun HavenConfig.muteRulesFor(npub: String): MuteRules = MuteRulesCache.get(mutedFor(npub))

fun HavenConfig.muteRulesForActiveAccount(): MuteRules = muteRulesFor(activeOrOwnerNpub())

private object MuteRulesCache {
    @Volatile private var last: Pair<MutedThings, MuteRules> = MutedThings.EMPTY to MuteRules.NONE

    fun get(things: MutedThings): MuteRules {
        val held = last
        if (held.first == things) return held.second
        return MuteRules(things).also { last = things to it }
    }
}
