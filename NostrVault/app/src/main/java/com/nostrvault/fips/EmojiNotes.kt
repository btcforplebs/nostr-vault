package com.nostrvault.fips

import com.nostrvault.service.CustomEmoji
import com.nostrvault.service.EmojiListParse
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

/**
 * Emoji notes (RESEARCH/NV_CUSTOM_EMOJI_PLAN.md §4.1, fixtures docs/fixtures/emoji-notes/): a kind 1063 file note on
 * the vault's `/files` with `["t","nv-emoji"]`, saying a saved blob is a custom emoji. Its `["emoji", code, url]` tags
 * are the shortcodes that use the image, its `["a","30030:<pk>:<d>"]` tags the sets. A tag that breaks those shapes is
 * skipped; the note is still an emoji note. Same tags on Apple and web: change them only with Tod.
 */
@Serializable
data class EmojiNote(
    val id: String,
    val createdAt: Long,
    val sha256: String,
    val mime: String,
    val size: Long,
    /** (shortcode, url) pairs, each once, in tag order. */
    val codes: List<List<String>>,
    /** Set addresses, each once, in tag order. */
    val sets: List<String>,
) {
    companion object {
        const val TOPIC = "nv-emoji"

        /** The note's tags: a file note's ([FileNote.tags]) plus the emoji ones, or null when the vault would refuse it. */
        fun tags(
            sha256: String,
            mime: String,
            size: Long,
            owner: String,
            servers: List<String>,
            codes: List<Pair<String, String>>,
            sets: List<String>,
        ): List<List<String>>? {
            val base = FileNote.tags(sha256, mime, size, owner, servers) ?: return null
            val extra = mutableListOf(listOf("t", TOPIC))
            codes.filter { (c, u) -> CustomEmoji.isValidShortcode(c) && CustomEmoji.isValidURL(u) }.distinct()
                .forEach { (c, u) -> extra += listOf("emoji", c, u) }
            sets.filter { EmojiListParse.setRef(it) != null }.distinct().forEach { extra += listOf("a", it) }
            return base + extra
        }

        /** Whether a `/files` event is an emoji note: a valid file note tagged `t` nv-emoji. */
        fun isEmojiNote(event: JsonObject): Boolean = parse(event) != null

        /** An emoji note, or null for a plain file note or anything that is not a file note at all. */
        fun parse(event: JsonObject): EmojiNote? {
            val note = FileNote.parse(event) ?: return null
            val tags = rawTags(event)
            if (tags.none { it.size >= 2 && it[0] == "t" && it[1] == TOPIC }) return null
            val codes = tags.filter { it.size >= 3 && it[0] == "emoji" && CustomEmoji.isValidShortcode(it[1]) && CustomEmoji.isValidURL(it[2]) }
                .map { listOf(it[1], it[2]) }.distinct()
            val sets = tags.filter { it.size >= 2 && it[0] == "a" && EmojiListParse.setRef(it[1]) != null }
                .map { it[1] }.distinct()
            return EmojiNote(note.id, note.createdAt, note.sha256, note.mime, note.size, codes, sets)
        }

        private fun rawTags(event: JsonObject): List<List<String>> =
            (event["tags"] as? JsonArray).orEmpty().map { tag ->
                (tag as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.contentOrNull }.orEmpty()
            }
    }
}

/**
 * Every live `/files` note the owner's devices have, by hash, split into emoji and plain notes, with deletions kept so
 * a replayed note never comes back. The Media rule: a hash is hidden when every live note for it is an emoji note; one
 * plain note keeps it in Media. Not thread-safe: one owner applies events in order.
 */
@Serializable
class EmojiNoteIndex(
    /** Only this owner's notes count; null takes the room's word. */
    var owner: String? = null,
    private val emoji: MutableMap<String, EmojiNote> = mutableMapOf(),
    /** Plain file notes: id → hash. */
    private val plain: MutableMap<String, String> = mutableMapOf(),
    private val deleted: MutableSet<String> = mutableSetOf(),
) {
    /** Apply one `/files` event; true when it changed what the index says. */
    fun apply(event: JsonObject): Boolean {
        FileNote.parse(event)?.let { note ->
            if (owner != null && owner != note.owner) return false
            if (note.id in deleted || note.id in emoji || note.id in plain) return false
            val e = EmojiNote.parse(event)
            if (e != null) emoji[e.id] = e else plain[note.id] = note.sha256
            return true
        }
        FileNoteDeletion.parse(event)?.let { deletion ->
            var changed = false
            for (id in deletion.noteIds) {
                deleted += id
                if (emoji.remove(id) != null) changed = true
                if (plain.remove(id) != null) changed = true
            }
            return changed
        }
        return false
    }

    /** A note this device just saved, before the room echoes it back (same id: the echo is a no-op). */
    fun addOwn(note: EmojiNote) {
        if (note.id in deleted || note.id in emoji) return
        emoji[note.id] = note
    }

    val emojiNotes: List<EmojiNote> get() = emoji.values.sortedWith(compareBy<EmojiNote> { it.createdAt }.thenBy { it.id })

    /** Hashes every live note of which is an emoji note. */
    val hiddenFromMedia: Set<String>
        get() {
            val plainHashes = plain.values.toSet()
            return emoji.values.map { it.sha256 }.filterTo(sortedSetOf()) { it !in plainHashes }
        }

    /** (shortcode, url) pairs across every emoji note for [sha256], each once. */
    fun codes(sha256: String): List<List<String>> = emojiNotes.filter { it.sha256 == sha256 }.flatMap { it.codes }.distinct()

    /** Set addresses across every emoji note for [sha256], each once. */
    fun sets(sha256: String): List<String> = emojiNotes.filter { it.sha256 == sha256 }.flatMap { it.sets }.distinct()

    /** Emoji url → saved hash: how an emoji draws from the vault copy instead of its link. */
    fun hashByUrl(): Map<String, String> = buildMap {
        for (n in emojiNotes) for (c in n.codes) putIfAbsent(c[1], n.sha256)
    }

    /** Emoji hashes saved for a set: what the Emoji page counts as saved. */
    fun hashesForSet(address: String): Set<String> = emoji.values.filter { address in it.sets }.mapTo(mutableSetOf()) { it.sha256 }
}
