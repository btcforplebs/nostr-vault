package com.nostrvault.ui.components

import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.sp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The selectable note body's links: same ranges and targets as the tap path. */
class ContentLinksTest {

    private val annotated = buildAnnotatedString {
        append("hi ")
        pushStringAnnotation("profile", "abc123")
        withStyle(SpanStyle(fontSize = 12.sp)) { append("@alice") }
        pop()
        append(" see ")
        pushStringAnnotation("url", "https://example.com/x")
        append("example.com/x")
        pop()
        append(" ")
        pushStringAnnotation("hashtag", "nostr")
        append("#Nostr")
        pop()
    }

    private fun links(hashtags: Boolean, onLink: (String, String) -> Unit = { _, _ -> }) =
        withContentLinks(annotated, hashtags, onLink).getLinkAnnotations(0, annotated.length)

    @Test
    fun `each annotation becomes a link over its own range`() {
        val ranges = links(hashtags = true).map { it.start until it.end }
        assertEquals(listOf(3 until 9, 14 until 27, 28 until 34), ranges)
    }

    @Test
    fun `a link reports its annotation's tag and item`() {
        val hits = mutableListOf<Pair<String, String>>()
        for (link in links(hashtags = true) { tag, item -> hits += tag to item }) {
            (link.item as LinkAnnotation.Clickable).linkInteractionListener!!.onClick(link.item)
        }
        assertEquals(
            listOf("profile" to "abc123", "url" to "https://example.com/x", "hashtag" to "nostr"),
            hits,
        )
    }

    @Test
    fun `hashtags stay inert where no hashtag feed can open`() {
        val tags = links(hashtags = false).map { (it.item as LinkAnnotation.Clickable).tag }
        assertEquals(listOf("profile", "url"), tags)
    }

    @Test
    fun `text and styling are untouched`() {
        val linked = withContentLinks(annotated, true) { _, _ -> }
        assertEquals(annotated.text, linked.text)
        assertEquals(annotated.spanStyles, linked.spanStyles)
        assertTrue(linked.getStringAnnotations("profile", 3, 3).isNotEmpty())
    }
}
