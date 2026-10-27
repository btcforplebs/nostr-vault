package com.nostrvault.service

import kotlinx.serialization.Serializable

/**
 * The hashtags an account follows: its NIP-51 interest list (kind 10015).
 * Other clients read and write the same list, so tags we don't touch (`a`
 * refs to interest sets, odd-cased `t`s) and the content (private items) ride
 * along unchanged on every publish. Port of iOS `InterestList`.
 */
@Serializable
data class InterestList(
    val tags: List<List<String>> = emptyList(),
    val content: String = "",
    val createdAt: Long = 0,
) {
    /** Followed hashtags, lowercase, in list order. */
    val hashtags: List<String>
        get() {
            val seen = HashSet<String>()
            return tags.mapNotNull { tag ->
                if (tag.size < 2 || tag[0] != "t") return@mapNotNull null
                normalize(tag[1]).takeIf { it.isNotEmpty() && seen.add(it) }
            }
        }

    operator fun contains(hashtag: String): Boolean = normalize(hashtag) in hashtags

    /**
     * Adds or removes one hashtag. Removing drops every case variant of it;
     * everything else stays as it was.
     */
    fun setting(hashtag: String, followed: Boolean): InterestList {
        val name = normalize(hashtag)
        if (name.isEmpty()) return this
        return if (followed) {
            if (name in this) this else copy(tags = tags + listOf(listOf("t", name)))
        } else {
            copy(tags = tags.filterNot { it.size >= 2 && it[0] == "t" && normalize(it[1]) == name })
        }
    }

    companion object {
        const val KIND = 10015

        /** NIP-24: hashtags are lowercase, no leading '#'. */
        fun normalize(hashtag: String): String = hashtag.trim().trimStart('#').lowercase()

        /** What a post's #hashtag may be: letters, digits, `_`, at least one letter. */
        private val HASHTAG = Regex("""[\p{L}\p{N}_]*\p{L}[\p{L}\p{N}_]*""")

        /**
         * Many hashtags typed or pasted at once — "#bitcoin #nostr, art" or one
         * per line — split on spaces, commas and '#'. [Parsed.hashtags] are
         * normalized, in typed order, each once; [Parsed.rejected] are the
         * pieces that can't be a hashtag ("#123", "c++"), as typed.
         */
        fun parseHashtags(input: String): Parsed {
            val hashtags = LinkedHashSet<String>()
            val rejected = mutableListOf<String>()
            for (piece in input.split(Regex("""[\s,;#]+"""))) {
                if (piece.isEmpty()) continue
                if (HASHTAG.matches(piece)) hashtags.add(normalize(piece)) else rejected.add(piece)
            }
            return Parsed(hashtags.toList(), rejected)
        }
    }

    data class Parsed(val hashtags: List<String>, val rejected: List<String>)
}
