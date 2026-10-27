package com.nostrvault.data.model

import com.nostrvault.util.findAllOnce

/**
 * A note cut at each link that gets a preview card, so each card draws where
 * its link was written instead of in a pile under the note. Port of iOS
 * `NoteURLs.segments` (#1246).
 */
object NoteLinkSegments {

    sealed class Segment {
        data class Text(val text: String) : Segment()
        data class Link(val url: String) : Segment()
    }

    /** Same URL rule the card list and the text renderer use. */
    private val URL_REGEX = Regex(
        """https?://[^\s<>")\]]*[^\s<>")\].,;:!?'"]""",
        RegexOption.IGNORE_CASE,
    )

    private val SPACE_RUN = Regex("""[ \t]{2,}""")

    /**
     * [content] in reading order: text pieces and the links in [cards].
     *
     * A card's URL is cut only where it is a whole URL match, so one inside a
     * longer kept URL stays text. A link written twice gets its card at the
     * first spot and leaves the text at the second. Text pieces are trimmed
     * with their space runs closed; empty ones are dropped.
     */
    fun split(content: String, cards: List<String>): List<Segment> {
        if (cards.isEmpty()) return piece(content)?.let { listOf(Segment.Text(it)) } ?: emptyList()
        val wanted = cards.toSet()
        val placed = HashSet<String>()
        val out = mutableListOf<Segment>()
        val pending = StringBuilder()
        var cursor = 0
        for (m in URL_REGEX.findAllOnce(content)) {
            if (m.value !in wanted) continue
            pending.append(content, cursor, m.range.first)
            cursor = m.range.last + 1
            if (!placed.add(m.value)) continue
            piece(pending.toString())?.let { out.add(Segment.Text(it)) }
            pending.setLength(0)
            out.add(Segment.Link(m.value))
        }
        pending.append(content, cursor, content.length)
        piece(pending.toString())?.let { out.add(Segment.Text(it)) }
        return out
    }

    private fun piece(text: String): String? =
        SPACE_RUN.replace(text, " ").trim().ifEmpty { null }
}
