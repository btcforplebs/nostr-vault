package com.nostrvault.ui.components

import org.junit.Assert.assertEquals
import org.junit.Test

/** A line-limited preview must not end on a blank line (the lone "..." under a reply). */
class NostrMentionsSqueezeTest {
    @Test fun blankLineBetweenParagraphsBecomesOneBreak() {
        // FreedomMoneyIsFuture's reply from Logen's screenshot, shortened.
        assertEquals("on your spamchain.\nI think you are sick",
            NostrMentions.squeezeBlankLines("on your spamchain.\n\nI think you are sick"))
    }

    @Test fun runsAndWhitespaceOnlyLinesSqueezeToo() {
        assertEquals("a\nb", NostrMentions.squeezeBlankLines("a\n \n\t\n\nb"))
    }

    @Test fun singleBreaksAreKept() {
        assertEquals("a\nb\nc", NostrMentions.squeezeBlankLines("a\nb\nc"))
    }
}
