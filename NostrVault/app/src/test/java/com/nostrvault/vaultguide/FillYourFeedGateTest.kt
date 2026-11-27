package com.nostrvault.vaultguide

import com.nostrvault.tutorials.TutorialStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The hard 5-follow rule for new accounts. Same cases as iOS `FillYourFeedGateTests`. */
class FillYourFeedGateTest {
    private class DictStore : TutorialStore {
        val values = HashMap<String, String?>()
        override fun getString(key: String): String? = values[key]
        override fun putString(key: String, value: String?) { values[key] = value }
    }

    private fun meter(n: Int, earned: Boolean = false) = VaultMeter.of((0 until n).map { "p$it" }, "me", earned)

    /** Skip-referrer → topics (0) and scan-join → Discover (1-4) are both held until 5. */
    @Test fun newAccountLockedUntilFive() {
        for (n in 0..4) assertTrue("$n", FillYourFeedGate.isLocked(required = true, meter = meter(n)))
        assertFalse(FillYourFeedGate.isLocked(required = true, meter = meter(5)))
        assertFalse(FillYourFeedGate.isLocked(required = true, meter = meter(9)))
    }

    /** Once built, unfollowing back under 5 doesn't lock it again. */
    @Test fun builtWebOfTrustStaysUnlocked() {
        assertFalse(FillYourFeedGate.isLocked(required = true, meter = meter(3, earned = true)))
    }

    /** Accounts setup didn't make here (sign-ins, older accounts) keep the old way out. */
    @Test fun existingAccountsNeverLocked() {
        for (n in 0..6) assertFalse("$n", FillYourFeedGate.isLocked(required = false, meter = meter(n)))
    }

    @Test fun meterSaysHowManyAreLeft() {
        assertEquals("Follow 5 more to finish", FillYourFeedGuide.meterSubtitle(meter(0), locked = true))
        assertEquals("Follow 2 more to finish", FillYourFeedGuide.meterSubtitle(meter(3), locked = true))
        assertEquals("Follow 1 more to finish", FillYourFeedGuide.meterSubtitle(meter(4), locked = true))
        assertEquals("Look before you follow", FillYourFeedGuide.meterSubtitle(meter(3), locked = false))
        assertEquals("5 people followed", FillYourFeedGuide.meterSubtitle(meter(5), locked = true))
    }

    @Test fun storeIsPerAccountAndOnlyForMarkedKeys() {
        val store = FillYourFeedGateStore(DictStore())
        assertFalse(store.isRequired("a"))
        store.require("a")
        assertTrue(store.isRequired("a"))
        assertFalse(store.isRequired("b"))
        store.require("")
        assertFalse(store.isRequired(""))
    }
}
