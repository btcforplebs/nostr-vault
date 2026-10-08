package com.nostrvault.vaultguide

import com.nostrvault.tutorials.TutorialStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Same cases as iOS `FillYourFeedGuideTests`. */
class FillYourFeedGuideTest {
    private class DictStore : TutorialStore {
        val values = HashMap<String, String?>()
        override fun getString(key: String): String? = values[key]
        override fun putString(key: String, value: String?) { values[key] = value }
    }

    private fun meter(n: Int, earned: Boolean = false) = VaultMeter.of((0 until n).map { "p$it" }, "me", earned)

    @Test fun entryResumesOnTheFeedOnceTheMeterIsOn() {
        assertEquals(FillYourFeedPhase.INTRO, FillYourFeedGuide.entryPhase(meterOn = false))
        assertEquals(FillYourFeedPhase.BROWSING, FillYourFeedGuide.entryPhase(meterOn = true))
    }

    @Test fun meterHiddenDuringIntroAndTopicsAndWhenOff() {
        assertFalse(FillYourFeedGuide.showsMeter(FillYourFeedPhase.INTRO, true))
        assertFalse(FillYourFeedGuide.showsMeter(FillYourFeedPhase.TOPICS, true))
        for (phase in listOf(FillYourFeedPhase.OFF, FillYourFeedPhase.HINT, FillYourFeedPhase.BROWSING,
                FillYourFeedPhase.READY)) {
            assertTrue(phase.name, FillYourFeedGuide.showsMeter(phase, true))
            assertFalse(phase.name, FillYourFeedGuide.showsMeter(phase, false))
        }
    }

    @Test fun showPostsButton() {
        assertEquals("Pick at least one", FillYourFeedGuide.showPostsTitle(0))
        assertEquals("Show posts (3)", FillYourFeedGuide.showPostsTitle(3))
    }

    @Test fun meterTextsAcrossStages() {
        assertEquals("3 of 5", FillYourFeedGuide.meterTitle(meter(3), compact = false))
        assertEquals("3/5", FillYourFeedGuide.meterTitle(meter(3), compact = true))
        assertEquals("Look before you follow", FillYourFeedGuide.meterSubtitle(meter(3)))
        assertEquals("3/5", FillYourFeedGuide.pillText(meter(3)))
        assertEquals("Web of trust", FillYourFeedGuide.meterTitle(meter(5), compact = false))
        assertEquals("5 people followed", FillYourFeedGuide.meterSubtitle(meter(5)))
        assertEquals("Web of trust", FillYourFeedGuide.pillText(meter(5)))
    }

    @Test fun earnedMasterStaysGoldBelowFive() {
        val m = meter(3, earned = true)
        assertEquals("Web of trust", FillYourFeedGuide.pillText(m))
        assertEquals(1f, FillYourFeedGuide.ringFraction(m), 0.0001f)
        assertEquals(0.4f, FillYourFeedGuide.ringFraction(meter(2)), 0.0001f)
    }

    @Test fun meterStoreIsPerAccountAndIgnoresBlankAccount() {
        val store = FeedMeterStore(DictStore())
        assertFalse(store.isOn("a"))
        store.set(true, "a")
        assertTrue(store.isOn("a"))
        assertFalse(store.isOn("b"))
        store.set(false, "a")
        assertFalse(store.isOn("a"))
        store.set(true, "")
        assertFalse(store.isOn(""))
    }
}
