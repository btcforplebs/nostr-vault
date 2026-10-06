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
    }
}
