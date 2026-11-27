package com.nostrvault.data.model

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

/**
 * A NIP-51 kind 10000 mute list: its people, and (MuteListHides.kt) its
 * muted words, hashtags and threads. Public entries are the `p`
 * tags. A private part, when there is one, is the content: a JSON array of
 * tags encrypted to the author's own key, NIP-44 or (older clients) NIP-04.
 * Only the author can open it. Web: web-vault/src/net/blocks.js.
 */
object MuteList {
    private val HEX64 = Regex("^[0-9a-f]{64}$")

    /**
     * [private] is null when there is a private part this device could not
     * open (no key here, signer offline, unreadable): it is unknown, not empty.
     */
    data class Entries(
        val public: List<String>,
        val private: List<String>?,
        /** Words, hashtags and threads in the public tags ([MutedThings]). */
        val publicMuted: MutedThings = MutedThings.EMPTY,
        /** The same in the private part; null when it could not be opened. */
        val privateMuted: MutedThings? = emptyMutedOrNull(private),
    )

    private fun emptyMutedOrNull(private: List<String>?): MutedThings? = if (private == null) null else MutedThings.EMPTY

    /** Hex pubkeys of the `p` entries, lowercased and deduped. */
    fun people(tags: List<List<String>>): List<String> =
        tags.filter { it.size >= 2 && it[0] == "p" }
            .map { it[1].trim().lowercase() }
            .filter { HEX64.matches(it) }
            .distinct()

    /** NIP-04 ciphertext carries "?iv="; NIP-44 is plain base64. */
    fun isNip04(content: String): Boolean = content.contains("?iv=")

    /** The private part's tags, or null when [plaintext] is not a JSON array of tags. */
    fun privateTags(plaintext: String): List<List<String>>? = runCatching {
        (Json.parseToJsonElement(plaintext) as JsonArray).mapNotNull { tag ->
            (tag as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
        }
    }.getOrNull()

    /** [decrypt] opens the content: (ciphertext, isNip04) -> plaintext, or null. */
    suspend fun entries(
        tags: List<List<String>>,
        content: String,
        decrypt: suspend (String, Boolean) -> String?,
    ): Entries {
        val public = people(tags)
        val publicMuted = MutedThings.from(tags)
        if (content.isBlank()) return Entries(public, emptyList(), publicMuted, MutedThings.EMPTY)
        val plaintext = runCatching { decrypt(content, isNip04(content)) }.getOrNull()
        val opened = plaintext?.let(::privateTags)
        return Entries(public, opened?.let(::people), publicMuted, opened?.let(MutedThings::from))
    }
}
