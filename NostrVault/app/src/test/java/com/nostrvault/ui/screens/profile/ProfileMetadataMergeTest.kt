package com.nostrvault.ui.screens.profile

import com.nostrvault.service.NostrService
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ProfileMetadataMergeTest {
    private val relayContent = """{"name":"sat","display_name":"Satoshi","about":"hi","banner":"https://b/x.jpg","lud06":"lnurl1abc","bot":false,"website":"https://a.example"}"""
    private val shown = mapOf(
        "display_name" to "Satoshi", "name" to "sat", "about" to "hi", "picture" to "",
        "nip05" to "", "lud16" to "", "website" to "https://a.example",
    )

    @Test fun unknownKeysAreKept() {
        val out = ProfileMetadataMerge.merge(ProfileMetadataMerge.parseContent(relayContent), shown, shown + ("about" to "new bio"))
        assertEquals("https://b/x.jpg", out["banner"]!!.jsonPrimitive.content)
        assertEquals("lnurl1abc", out["lud06"]!!.jsonPrimitive.content)
        assertEquals(JsonPrimitive(false), out["bot"])
    }

    @Test fun editedFieldIsReplacedAndTrimmed() {
        val out = ProfileMetadataMerge.merge(ProfileMetadataMerge.parseContent(relayContent), shown,
            shown + ("about" to "  new bio ") + ("lud16" to "me@wallet.example"))
        assertEquals("new bio", out["about"]!!.jsonPrimitive.content)
        assertEquals("me@wallet.example", out["lud16"]!!.jsonPrimitive.content)
        assertEquals("sat", out["name"]!!.jsonPrimitive.content)
    }

    @Test fun bannerEditIsAppliedAndClearingRemovesIt() {
        val base = ProfileMetadataMerge.parseContent(relayContent)
        val shownBanner = shown + ("banner" to "https://b/x.jpg")
        val replaced = ProfileMetadataMerge.merge(base, shownBanner, shownBanner + ("banner" to "https://b/new.jpg"))
        assertEquals("https://b/new.jpg", replaced["banner"]!!.jsonPrimitive.content)
        val cleared = ProfileMetadataMerge.merge(base, shownBanner, shownBanner + ("banner" to ""))
        assertFalse(cleared.containsKey("banner"))
    }

    @Test fun clearedFieldIsRemoved() {
        val out = ProfileMetadataMerge.merge(ProfileMetadataMerge.parseContent(relayContent), shown, shown + ("website" to "  "))
        assertFalse(out.containsKey("website"))
        assertTrue(out.containsKey("name"))
    }

    @Test fun untouchedFieldKeepsTheNewerRelayValue() {
        // The form opened on a stale cache ("hi"); the relays hold a newer bio.
        val base = ProfileMetadataMerge.parseContent("""{"about":"newer bio","name":"sat"}""")
        val out = ProfileMetadataMerge.merge(base, shown, shown + ("name" to "satoshi"))
        assertEquals("newer bio", out["about"]!!.jsonPrimitive.content)
        assertEquals("satoshi", out["name"]!!.jsonPrimitive.content)
    }

    @Test fun unreadableContentStartsEmpty() {
        assertTrue(ProfileMetadataMerge.parseContent("not json").isEmpty())
        assertTrue(ProfileMetadataMerge.parseContent("[1,2]").isEmpty())
        assertTrue(ProfileMetadataMerge.parseContent(null).isEmpty())
    }

    @Test fun noneIsConfirmedOnlyWhenEveryRelayAnswered() {
        assertTrue(NostrService.ReplaceableLookup(null, asked = 3, answered = 3).confirmedNone)
        assertFalse(NostrService.ReplaceableLookup(null, asked = 3, answered = 2).confirmedNone)
        assertFalse(NostrService.ReplaceableLookup(null, asked = 0, answered = 0).confirmedNone)
    }
}
