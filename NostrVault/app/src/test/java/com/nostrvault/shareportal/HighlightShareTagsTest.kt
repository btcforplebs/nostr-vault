package com.nostrvault.shareportal

import com.nostrvault.service.shareportal.handlers.HighlightShareTags
import org.junit.Assert.assertEquals
import org.junit.Test

class HighlightShareTagsTest {
    @Test fun trimmedPassageKeepsTheSelectionAsContext() {
        assertEquals(
            listOf(
                listOf("r", "https://e.com/post", "source"),
                listOf("context", "The whole sentence, and more."),
                listOf("comment", "So true"),
                listOf("alt", "Highlight: \"The whole sentence\""),
            ),
            HighlightShareTags.tags("https://e.com/post", " The whole sentence, and more. ", " The whole sentence ", " So true "),
        )
    }

    @Test fun untrimmedPassageHasNoContextAndNoCommentWhenBlank() {
        assertEquals(
            listOf(listOf("r", "https://e.com", "source"), listOf("alt", "Highlight: \"Same\"")),
            HighlightShareTags.tags("https://e.com", "Same", "Same", "  "),
        )
    }

    @Test fun noUrlMeansNoSourceTag() {
        assertEquals(listOf(listOf("alt", "Highlight: \"Words\"")), HighlightShareTags.tags(null, null, "Words", ""))
    }
}
