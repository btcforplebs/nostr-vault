package com.nostrvault.data.model

/**
 * NIP-10: which event a note answers, read from its `e` tags. The Swift twin is
 * HavenApp/HavenApp/Models/NIP10Thread.swift; keep the rules identical.
 *
 * - An `e` tag marked "reply" names the parent.
 * - Failing that, one marked "root" does: a direct reply to the root.
 * - Unmarked tags are the deprecated positional form, where the last one is
 *   the parent.
 * - A tag marked "mention" is a quote, never a parent. Treating it as one hung
 *   every quote under the note it quotes, and a reply that also quoted
 *   something came out as a reply to the quote, because the mention is usually
 *   the last `e` tag.
 */
object NIP10Thread {
    fun parentEventId(tags: List<List<String>>): String? {
        val eTags = tags.filter { it.size >= 2 && it[0] == "e" }
        eTags.firstOrNull { marker(it) == "reply" }?.let { return it[1] }
        eTags.firstOrNull { marker(it) == "root" }?.let { return it[1] }
        return eTags.lastOrNull { marker(it) != "mention" }?.get(1)
    }

    private fun marker(tag: List<String>): String = if (tag.size >= 4) tag[3] else ""
}
