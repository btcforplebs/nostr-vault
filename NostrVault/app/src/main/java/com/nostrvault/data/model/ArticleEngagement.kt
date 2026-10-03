package com.nostrvault.data.model

/**
 * Tags for reacting to and highlighting a long-form article.
 *
 * Mirrors HavenApp/HavenApp/Models/ArticleEngagement.swift. An article is
 * addressable, so a like or a highlight names it by its `a` coordinate as
 * well as this version's `e` id; otherwise clients that count by address
 * never see it, and an edit orphans it.
 */
object ArticleEngagement {
    const val HIGHLIGHT_KIND = 9802

    /** NIP-25 reaction tags. `a` only appears when the event is addressable. */
    fun reactionTags(id: String, kind: Int, pubkey: String, tags: List<List<String>>, relayHint: String): List<List<String>> =
        buildList {
            add(listOf("e", id, relayHint, pubkey))
            NIP10Thread.coordinate(kind, pubkey, tags)?.let { add(listOf("a", it, relayHint)) }
            add(listOf("p", pubkey))
            add(listOf("k", kind.toString()))
        }

    /**
     * NIP-84 highlight tags. `context` is the surrounding paragraph and is only
     * sent when the highlight is a trimmed part of it; `comment` turns it into
     * a quote highlight.
     */
    fun highlightTags(
        id: String,
        kind: Int,
        pubkey: String,
        tags: List<List<String>>,
        relayHint: String,
        passage: String,
        context: String,
        comment: String,
    ): List<List<String>> = buildList {
        NIP10Thread.coordinate(kind, pubkey, tags)?.let { add(listOf("a", it, relayHint)) }
        add(listOf("e", id, relayHint))
        add(listOf("p", pubkey, relayHint, "author"))
        val p = passage.trim()
        val c = context.trim()
        if (c.isNotEmpty() && c != p) add(listOf("context", c))
        comment.trim().takeIf { it.isNotEmpty() }?.let { add(listOf("comment", it)) }
        add(listOf("alt", "Highlight: \"$p\""))
    }

    /**
     * The article split into blocks a reader can tap to highlight: runs of
     * text separated by blank lines, with fenced code kept whole.
     */
    fun blocks(markdown: String): List<String> {
        val out = mutableListOf<String>()
        val current = StringBuilder()
        var inFence = false
        fun flush() {
            val b = current.toString().trim()
            if (b.isNotEmpty()) out.add(b)
            current.clear()
        }
        for (line in markdown.lines()) {
            if (line.trimStart().startsWith("```")) inFence = !inFence
            if (!inFence && line.isBlank()) {
                flush()
            } else {
                if (current.isNotEmpty()) current.append('\n')
                current.append(line)
            }
        }
        flush()
        return out
    }

    private val linkPattern = Regex("""!?\[([^\]]*)]\([^)]*\)""")
    private val emphasisPattern = Regex("""(\*\*|__|\*|_|~~|`)""")
    private val linePrefixPattern = Regex("""^\s{0,3}(#{1,6}\s+|>\s?|[-*+]\s+|\d+[.)]\s+)""")

    /** The highlightable text of a markdown block, with markup stripped. */
    fun plainText(markdown: String): String =
        markdown.lines().joinToString("\n") { line ->
            linePrefixPattern.replace(line, "")
                .let { linkPattern.replace(it) { m -> m.groupValues[1] } }
                .let { emphasisPattern.replace(it, "") }
        }.trim()
}
