package com.nostrvault.service.emoji

/** The Media rule (custom emoji plan §4.1): a hash every live note of which is an emoji note is not a Media tile. */
object EmojiMediaRule {
    fun <T> shown(items: List<T>, hidden: Set<String>, sha256: (T) -> String): List<T> =
        if (hidden.isEmpty()) items else items.filterNot { sha256(it).lowercase() in hidden }
}
