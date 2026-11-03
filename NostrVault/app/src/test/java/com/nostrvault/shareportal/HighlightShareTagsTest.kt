package com.nostrvault.shareportal

import com.nostrvault.service.shareportal.handlers.HighlightShareTags
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class HighlightShareTagsTest {
    @Test fun trimmedPassageWithComment() {
        assertEquals(
            listOf(
                listOf("r", "https://e.com/post", "source"),
                listOf("comment", "So true"),
                listOf("alt", "Highlight: \"The whole sentence\""),
            ),
            HighlightShareTags.tags("https://e.com/post", " The whole sentence ", " So true "),
        )
    }

    /** Tron, PR 1610: text deleted from the passage must not ride along as `context`. */
    @Test fun deletedTextIsNotPublished() {
        val tags = HighlightShareTags.tags("https://e.com", "the quick brown fox jumps.", "")
        assertFalse(tags.flatten().any { it.contains("4471") })
        assertFalse(tags.any { it.first() == "context" })
    }

    @Test fun blankCommentIsLeftOut() {
        assertEquals(
            listOf(listOf("r", "https://e.com", "source"), listOf("alt", "Highlight: \"Same\"")),
            HighlightShareTags.tags("https://e.com", "Same", "  "),
        )
    }

    @Test fun noUrlMeansNoSourceTag() {
        assertEquals(listOf(listOf("alt", "Highlight: \"Words\"")), HighlightShareTags.tags(null, "Words", ""))
    }
}
