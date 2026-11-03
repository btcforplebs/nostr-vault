package com.nostrvault.shareportal

import com.nostrvault.shareportal.ShareFixtures.str
import com.nostrvault.shareportal.ShareFixtures.strings
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ShareClassifierTest {
    private val cases = ShareFixtures.load("classifier-cases.json")["cases"]!!.jsonArray

    @Test fun fixturesAreThere() {
        assertTrue("expected the shared fixture cases", cases.size >= 30)
    }

    @Test fun everySharedFixtureRanksAsExpected() {
        val failures = cases.mapNotNull { c ->
            val o = c.jsonObject
            val got = ShareClassifier.classify(ShareFixtures.input(o["input"]!!.jsonObject)).map { it.raw }
            val want = o["expect"]!!.strings()
            if (got == want) null else "${o.str("name")}: want $want, got $got"
        }
        assertEquals(failures.joinToString("\n"), emptyList<String>(), failures)
    }

    @Test fun neverRepeatsAnAction() {
        val all = ShareInput(
            url = "https://open.spotify.com/x", text = "lnbc2500u1pvjluezpp5qqqsyqcyq5rqwzq",
            selection = "s", files = listOf(ShareInputFile("application/pdf", "a.pdf"), ShareInputFile("image/png", "b.png")),
            ldTypes = listOf("Recipe", "Event"),
        )
        val got = ShareClassifier.classify(all)
        assertEquals(got.distinct(), got)
    }

    @Test fun hostIgnoresUserinfoAndPort() {
        assertEquals("youtube.com", ShareClassifier.host("https://me:pw@YouTube.com:443/watch"))
        assertNull(ShareClassifier.host("no scheme"))
    }

    @Test fun availabilityShowsOnlyReadyActions() {
        val ranked = listOf(ShareAction.BOOKMARK, ShareAction.HIGHLIGHT, ShareAction.PAY, ShareAction.UPLOAD)
        assertEquals(listOf(ShareAction.HIGHLIGHT, ShareAction.PAY, ShareAction.UPLOAD), ShareActionAvailability.available(ranked))
    }
}
