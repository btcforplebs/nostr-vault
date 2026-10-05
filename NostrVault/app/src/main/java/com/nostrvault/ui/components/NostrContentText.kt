package com.nostrvault.ui.components

import androidx.compose.foundation.text.ClickableText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.ui.navigation.LocalOpenHashtag
import com.nostrvault.ui.theme.*

/**
 * Renders note content with clickable nostr: mentions, URLs, and hashtags.
 *
 * - `nostr:npub1...` / `nostr:nprofile1...` → @displayName (clickable)
 * - `nostr:note1...` / `nostr:nevent1...` → stripped (rendered as QuotedNoteCard elsewhere)
 * - Bare URLs → clickable links in theme color
 * - `#hashtag` → theme-colored, opens that hashtag's feed ([LocalOpenHashtag])
 * - Media URLs → stripped (rendered as MediaPreviewRow elsewhere)
 * - [linkURLs] → stripped too, for callers that draw a LinkPreviewCard per
 *   link (#170 parity). A caller that draws no card must not pass them, or
 *   the link disappears from the note.
 */
@Composable
fun NostrContentText(
    content: String,
    profiles: Map<String, FeedProfile>,
    mediaURLs: Set<String> = emptySet(),
    linkURLs: Set<String> = emptySet(),
    onProfileClick: (String) -> Unit = {},
    onPlainTextClick: (() -> Unit)? = null,
    textColor: Color = PrimaryText,
    fontSize: TextUnit = 15.sp,
    lineHeight: TextUnit = 21.sp,
    modifier: Modifier = Modifier,
) {
    val colors = LocalNostrVaultColors.current
    val uriHandler = LocalUriHandler.current
    val openHashtag = LocalOpenHashtag.current

    // Parse structure ONCE per content. The regex passes + bech32 decode
    // (resolvePubkey) are the expensive part and depend only on the text, so
    // memoize them — otherwise they re-run on every recomposition (e.g. each
    // time the global profile map updates while scrolling), which is the main
    // feed-scroll jank source.
    val segments = remember(content, mediaURLs, linkURLs) { parseContentSegments(content, mediaURLs + linkURLs) }

    // Resolve mention display-names + build the styled string. This is cheap
    // (map lookups + string appends, no regex), so it can re-run when profiles
    // or theme change without hurting scroll.
    val annotated = remember(segments, profiles, colors.primary) {
        buildAnnotatedString {
            for (segment in segments) {
                when (segment) {
                    is ContentSegment.PlainText -> append(segment.text)

                    is ContentSegment.Mention -> {
                        val displayName = profiles[segment.pubkey]?.bestName
                            ?: (segment.pubkey.take(8) + "...")
                        pushStringAnnotation("profile", segment.pubkey)
                        withStyle(SpanStyle(color = colors.primary, fontWeight = FontWeight.Medium)) {
                            append("@$displayName")
                        }
                        pop()
                    }

                    is ContentSegment.Url -> {
                        pushStringAnnotation("url", segment.url)
                        withStyle(SpanStyle(color = colors.primary)) {
                            append(segment.displayUrl)
                        }
                        pop()
                    }

                    is ContentSegment.Hashtag -> {
                        pushStringAnnotation("hashtag", segment.tag)
                        withStyle(SpanStyle(color = colors.primary)) {
                            append(segment.text)
                        }
                        pop()
                    }

                    // Quoted note references and media URLs are stripped from text
                    is ContentSegment.QuoteRef, is ContentSegment.MediaUrl -> {}
                }
            }
        }
    }

    if (annotated.text.isBlank()) return

    @Suppress("DEPRECATION")
    ClickableText(
        text = annotated,
        style = TextStyle(
            color = textColor,
            fontSize = fontSize,
            lineHeight = lineHeight,
        ),
        onClick = { offset ->
            annotated.getStringAnnotations("profile", offset, offset).firstOrNull()?.let {
                onProfileClick(it.item)
                return@ClickableText
            }
            annotated.getStringAnnotations("url", offset, offset).firstOrNull()?.let {
                try { uriHandler.openUri(it.item) } catch (_: Exception) {}
                return@ClickableText
            }
            if (openHashtag != null) {
                annotated.getStringAnnotations("hashtag", offset, offset).firstOrNull()?.let {
                    openHashtag(it.item)
                    return@ClickableText
                }
            }
            // No annotation matched — plain text was tapped; propagate to parent
            onPlainTextClick?.invoke()
        },
        modifier = modifier,
    )
}

// ── Content parsing ──────────────────────────────────────────────

internal sealed class ContentSegment {
    data class PlainText(val text: String) : ContentSegment()
    data class Mention(val pubkey: String) : ContentSegment()
    data class Url(val url: String, val displayUrl: String) : ContentSegment()
    /** [text] as written ("#Bitcoin"); [tag] is what its feed asks for ("bitcoin"). */
    data class Hashtag(val text: String, val tag: String) : ContentSegment()
    data class QuoteRef(val identifier: String) : ContentSegment()
    data class MediaUrl(val url: String) : ContentSegment()
}

private val NOSTR_MENTION_REGEX = NostrMentions.MENTION_REGEX
private val NOSTR_QUOTE_REGEX = NostrMentions.QUOTE_REGEX

private val URL_REGEX = Regex(
    """https?://[^\s<>")\]]*[^\s<>")\].,;:!?'"]""",
    RegexOption.IGNORE_CASE,
)

/**
 * A #hashtag: letters/digits/underscore after a # that starts a word, with at
 * least one letter, so URL fragments (`page#top`), HTML entities, markdown
 * labels and issue numbers ("#123") stay plain. Same pattern as iOS
 * `NostrContentFormatter.hashtagRegex`.
 */
private val HASHTAG_REGEX = Regex(
    """(?<![\p{L}\p{N}_/#&\]\[])#([\p{L}\p{N}_]*\p{L}[\p{L}\p{N}_]*)""",
)

/** [strippedURLs] are dropped from the text: media, and links drawn as cards. */
internal fun parseContentSegments(
    content: String,
    strippedURLs: Set<String>,
): List<ContentSegment> {
    // Collect all matches with their ranges
    data class Match(val range: IntRange, val segment: ContentSegment)

    val matches = mutableListOf<Match>()

    // nostr: mentions (npub, nprofile). Display-name resolution is deferred to
    // render time so this parse stays content-only (and memoizable).
    for (m in NOSTR_MENTION_REGEX.findAll(content)) {
        val identifier = m.groupValues[1]
        val pubkey = NostrMentions.resolvePubkey(identifier)
        if (pubkey != null) {
            matches.add(Match(m.range, ContentSegment.Mention(pubkey)))
        }
    }

    // nostr: quote references (note, nevent, naddr) — stripped from display
    for (m in NOSTR_QUOTE_REGEX.findAll(content)) {
        matches.add(Match(m.range, ContentSegment.QuoteRef(m.groupValues[1])))
    }

    // URLs — split into media (stripped) vs regular (clickable)
    for (m in URL_REGEX.findAll(content)) {
        val url = m.value
        // Skip if this range overlaps a nostr: mention/quote already captured
        if (matches.any { it.range.first <= m.range.last && it.range.last >= m.range.first }) continue

        if (url in strippedURLs) {
            matches.add(Match(m.range, ContentSegment.MediaUrl(url)))
        } else {
            val displayUrl = url
                .removePrefix("https://")
                .removePrefix("http://")
                .removePrefix("www.")
                .take(50)
                .let { if (it.length == 50) "$it..." else it }
            matches.add(Match(m.range, ContentSegment.Url(url, displayUrl)))
        }
    }

    // Hashtags
    for (m in HASHTAG_REGEX.findAll(content)) {
        if (matches.any { it.range.first <= m.range.last && it.range.last >= m.range.first }) continue
        matches.add(Match(m.range, ContentSegment.Hashtag(m.value, m.groupValues[1].lowercase())))
    }

    // Sort by position and build segment list
    matches.sortBy { it.range.first }

    val segments = mutableListOf<ContentSegment>()
    var cursor = 0

    for (match in matches) {
        if (match.range.first > cursor) {
            segments.add(ContentSegment.PlainText(content.substring(cursor, match.range.first)))
        }
        segments.add(match.segment)
        cursor = match.range.last + 1
    }

    if (cursor < content.length) {
        segments.add(ContentSegment.PlainText(content.substring(cursor)))
    }

    return closeGaps(segments)
}

/**
 * Close the holes that stripped URLs and quote references leave behind, the
 * way iOS `stripURLs` does: "see https://x.com now" reads "see now", not
 * "see  now", and nothing hangs at either end. Text either side of a stripped
 * piece is joined first, so the gap that spans it collapses too.
 */
private fun closeGaps(segments: List<ContentSegment>): List<ContentSegment> {
    val joined = mutableListOf<ContentSegment>()
    for (segment in segments) {
        when (segment) {
            is ContentSegment.QuoteRef, is ContentSegment.MediaUrl -> {}
            is ContentSegment.PlainText -> {
                val last = joined.lastOrNull()
                if (last is ContentSegment.PlainText) {
                    joined[joined.lastIndex] = ContentSegment.PlainText(last.text + segment.text)
                } else {
                    joined.add(segment)
                }
            }
            else -> joined.add(segment)
        }
    }
    val tidied = joined.map {
        if (it is ContentSegment.PlainText) ContentSegment.PlainText(NostrMentions.collapseGaps(it.text)) else it
    }.toMutableList()
    (tidied.firstOrNull() as? ContentSegment.PlainText)?.let { tidied[0] = ContentSegment.PlainText(it.text.trimStart()) }
    (tidied.lastOrNull() as? ContentSegment.PlainText)?.let { tidied[tidied.lastIndex] = ContentSegment.PlainText(it.text.trimEnd()) }
    return tidied.filterNot { it is ContentSegment.PlainText && it.text.isEmpty() }
}
