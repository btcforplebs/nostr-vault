package com.nostrvault.shareportal

import com.nostrvault.service.shareportal.handlers.HighlightPageLink
import com.nostrvault.service.shareportal.handlers.HighlightPageLink.Check
import com.nostrvault.service.shareportal.handlers.HighlightShareTags
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

/** Same cases as SharePortalKitTests' HighlightPageLink tests (iOS). Logen 2026-11-04. */
class HighlightPageLinkTest {
    @Test fun readsATypedAddress() {
        assertEquals(Check.Empty, HighlightPageLink.check(""))
        assertEquals(Check.Empty, HighlightPageLink.check("  \n "))
        assertEquals(Check.Link("https://example.com/a?b=1"), HighlightPageLink.check(" https://example.com/a?b=1 "))
        assertEquals(Check.Link("HTTP://Example.com"), HighlightPageLink.check("HTTP://Example.com"))
        assertEquals(Check.Link("https://example.com/post"), HighlightPageLink.check("example.com/post"))
        assertEquals(Check.Link("https://www.nytimes.com"), HighlightPageLink.check("www.nytimes.com"))
    }

    @Test fun refusesWhatIsNotAWebAddress() {
        for (typed in listOf("hello world", "notalink", "javascript:alert(1)", "ftp://example.com", "//example.com",
            "https://", "https://localhost", "example.", "nostr:npub1abc", "https://exa mple.com")) {
            assertEquals(typed, Check.NotALink, HighlightPageLink.check(typed))
            assertNull(typed, HighlightPageLink.link(typed))
        }
    }

    @Test fun typedPageLinkGoesOutAsTheSourceTag() {
        val tags = HighlightShareTags.tags(HighlightPageLink.link("example.com/a"), "words", "")
        assertEquals(listOf("r", "https://example.com/a", "source"), tags.first())
        assertFalse(HighlightShareTags.tags(HighlightPageLink.link(""), "words", "").any { it.first() == "r" })
    }
}
