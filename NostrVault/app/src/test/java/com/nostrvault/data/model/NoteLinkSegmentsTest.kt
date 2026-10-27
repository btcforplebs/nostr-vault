package com.nostrvault.data.model

import com.nostrvault.data.model.NoteLinkSegments.Segment.Link
import com.nostrvault.data.model.NoteLinkSegments.Segment.Text
import org.junit.Assert.assertEquals
import org.junit.Test

/** A link's card draws where the author wrote the link, not under the note (iOS NoteSegmentsTests, #1246). */
class NoteLinkSegmentsTest {

    @Test fun `card sits between the text around it`() {
        val text = "Read this https://a.com/post first.\n\nThen the rest."
        assertEquals(
            listOf(Text("Read this"), Link("https://a.com/post"), Text("first.\n\nThen the rest.")),
            NoteLinkSegments.split(text, listOf("https://a.com/post")),
        )
    }

    @Test fun `two links keep their order and the text between`() {
        assertEquals(
            listOf(Text("one"), Link("https://a.com"), Text("two"), Link("https://b.com"), Text("three")),
            NoteLinkSegments.split("one https://a.com two https://b.com three", listOf("https://a.com", "https://b.com")),
        )
    }

    @Test fun `link at start or end leaves no empty text`() {
        assertEquals(listOf(Link("https://a.com")), NoteLinkSegments.split("https://a.com", listOf("https://a.com")))
        assertEquals(listOf(Link("https://a.com"), Text("hi")), NoteLinkSegments.split("https://a.com hi\n", listOf("https://a.com")))
        assertEquals(listOf(Text("hi"), Link("https://a.com")), NoteLinkSegments.split("hi https://a.com", listOf("https://a.com")))
    }

    @Test fun `link written twice gets one card at its first spot`() {
        assertEquals(
            listOf(Text("a"), Link("https://a.com"), Text("b c")),
            NoteLinkSegments.split("a https://a.com b https://a.com c", listOf("https://a.com")),
        )
    }

    @Test fun `links past the cap stay in the text`() {
        assertEquals(
            listOf(Text("see"), Link("https://a.com"), Text("and https://a.com/login")),
            NoteLinkSegments.split("see https://a.com and https://a.com/login", listOf("https://a.com")),
        )
    }

    @Test fun `trailing punctuation stays with the text`() {
        assertEquals(
            listOf(Text("see"), Link("https://x.com/a"), Text(". now")),
            NoteLinkSegments.split("see https://x.com/a. now", listOf("https://x.com/a")),
        )
    }

    @Test fun `invoice text is left for the invoice path`() {
        val invoice = "lnbc1" + "q".repeat(120)
        assertEquals(
            listOf(Text("pay $invoice or"), Link("https://a.com")),
            NoteLinkSegments.split("pay $invoice or https://a.com", listOf("https://a.com")),
        )
    }

    @Test fun `no cards is one text piece`() {
        assertEquals(listOf(Text("just words")), NoteLinkSegments.split("  just  words ", emptyList()))
        assertEquals(emptyList<NoteLinkSegments.Segment>(), NoteLinkSegments.split("   ", emptyList()))
    }
}
