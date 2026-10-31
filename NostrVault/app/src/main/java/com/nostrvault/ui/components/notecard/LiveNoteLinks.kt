package com.nostrvault.ui.components

import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.LiveStream
import com.nostrvault.data.model.QuoteRef

/**
 * A note that quotes a live stream (`nostr:naddr1…` of a kind 30311) is drawn
 * with the stream's Live card, so the links that repeat the card leave it:
 * any HLS playlist (`.m3u8`), and once the stream event is loaded, its own
 * `streaming`, `recording`, `image` and `thumb` URLs. The text loses those
 * links and the live naddr, and blank lines close up, so heading + card is
 * all that shows. Older "Share as a note" posts (heading, cover, playlist,
 * naddr) read the same as new ones. Pure, for JVM tests.
 * iOS / web: the same rule in their note renderers.
 */
internal object LiveNoteLinks {

    /** The note's quote keys that name a live stream. */
    fun liveQuotes(quotedIds: List<String>): List<String> =
        quotedIds.filter { QuoteRef.parse(it)?.kind == LiveStream.KIND }

    /** An http(s) link whose path ends `.m3u8`. */
    fun isPlaylist(url: String): Boolean {
        val scheme = url.substringBefore(':').lowercase()
        val path = url.substringBefore('?').substringBefore('#').lowercase()
        return (scheme == "http" || scheme == "https") && path.endsWith(".m3u8")
    }

    /** The stream event's own links: what its card already draws or plays. */
    fun streamUrls(tags: List<List<String>>): Set<String> =
        tags.filter { it.size >= 2 && it[0] in STREAM_TAGS }.map { it[1].trim() }.filter { it.isNotEmpty() }.toSet()

    /**
     * Of [links] (the note's media and card links), the ones to drop. Empty
     * unless the note quotes a live stream. [quoted] is the loaded quotes by key.
     */
    fun hidden(links: List<String>, quotedIds: List<String>, quoted: Map<String, FeedNote>): Set<String> {
        val live = liveQuotes(quotedIds)
        if (live.isEmpty()) return emptySet()
        val known = live.flatMap { key -> quoted[key]?.tags?.let(::streamUrls).orEmpty() }.toSet()
        return links.filter { isPlaylist(it) || it in known }.toSet()
    }

    /**
     * [content] without the [hidden] links and the live-stream `nostr:naddr1…`
     * references, blank lines squeezed to one and the ends trimmed. [content]
     * unchanged when the note quotes no live stream.
     */
    fun body(content: String, hidden: Set<String>, decoder: QuoteRef.Decoder): String {
        val liveRefs = QuoteRef.identifiers(content).filter { id ->
            id.startsWith("naddr1", ignoreCase = true) && decoder.naddrToCoordinate(id)?.kind == LiveStream.KIND
        }
        if (liveRefs.isEmpty()) return content
        var text = content
        for (url in hidden) text = Regex(Regex.escape(url) + """(?=\s|$)""").replace(text, "")
        for (ref in liveRefs) text = Regex("""(?:nostr:)?""" + Regex.escape(ref), RegexOption.IGNORE_CASE).replace(text, "")
        text = text.lines().joinToString("\n") { it.trimEnd() }
        return BLANK_RUN.replace(text, "\n\n").trim()
    }

    private val STREAM_TAGS = setOf("streaming", "recording", "image", "thumb")
    private val BLANK_RUN = Regex("""\n{3,}""")
}
