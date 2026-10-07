package com.nostrvault.vaultguide

/**
 * Topics for the "Fill your vault" guide. They are words, not people: picking
 * one follows a hashtag, and every person the user then follows is their own
 * choice. iOS keeps the same lists in VaultTopics.swift; change both.
 */
object VaultTopics {
    /** The 20 shown first. */
    val starter: List<String> = listOf(
        "bitcoin", "nostr", "photography", "art", "music",
        "food", "outdoors", "tech", "gaming", "books",
        "fitness", "science", "memes", "travel", "pets",
        "film", "design", "privacy", "farming", "history",
    )

    /** Behind "More topics", after the starter 20. Any hashtag can also be typed. */
    val more: List<String> = listOf(
        "anime", "astronomy", "beer", "cars", "chess", "coffee",
        "comedy", "cooking", "crypto", "cycling", "dogs", "cats", "economics",
        "education", "environment", "fashion", "fishing", "football",
        "gardening", "health", "hiking", "homestead", "jazz", "lightning",
        "linux", "mathematics", "meditation", "motorcycles", "nature",
        "news", "opensource", "parenting", "philosophy", "plebchain",
        "podcasts", "poetry", "programming", "running", "selfhosting",
        "skateboarding", "space", "sports", "surfing", "writing", "zap",
    ).filter { it !in starter }

    /** What someone typed, as a hashtag: no leading #, lowercase, no spaces. Null when nothing is left. */
    fun normalize(typed: String): String? {
        val tag = typed.trim().trimStart('#').lowercase().filterNot { it.isWhitespace() }
        return tag.ifEmpty { null }
    }
}
