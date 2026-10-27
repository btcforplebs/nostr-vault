package com.nostrvault.setup

import com.nostrvault.ui.screens.SetupPath
import com.nostrvault.ui.screens.WizardStep
import com.nostrvault.ui.screens.withReferrerStep
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class ReferrerFollowsTest {
    @After fun reset() { ReferrerFollows.clear(); ReferrerFollows.prefill = null }

    @Test fun `most-followed first, ties keep their list order, ten at most`() {
        val follows = (1..15).map { "k$it" }
        val vouches = mapOf("k9" to 7, "k3" to 7, "k12" to 2)
        val picks = ReferrerFollows.suggestions("ref", follows, vouches)
        assertEquals(10, picks.size)
        assertEquals(listOf("k3", "k9", "k12", "k1", "k2", "k4"), picks.take(6))
    }

    @Test fun `vouches count the referrer's follows' lists only, never a self-follow`() {
        val a = "a".repeat(64); val b = "b".repeat(64); val c = "c".repeat(64); val x = "e".repeat(64)
        val lists = mapOf(a to listOf(a, b, c, c), b to listOf(c), x to listOf(b, b))
        assertEquals(mapOf(b to 1, c to 2), ReferrerFollows.vouches(listOf(a, b, c), lists))
    }

    @Test fun `a follow list is its p tags, hex only, once each`() {
        val a = "a".repeat(64)
        val tags = listOf(listOf("p", a.uppercase()), listOf("p", a), listOf("e", "f".repeat(64)), listOf("p", "short"), listOf("p"))
        assertEquals(listOf(a), ReferrerFollows.follows(tags))
    }

    @Test fun `never the referrer, you, or a repeat`() {
        val picks = ReferrerFollows.suggestions("ref", listOf("ref", "me", "a", "a", "b"), mapOf("ref" to 99, "me" to 50), skip = setOf("me"))
        assertEquals(listOf("a", "b"), picks)
    }

    @Test fun `picks are taken once, referrer first`() {
        ReferrerFollows.choose("ref", listOf("a", "ref", "b"))
        assertEquals(listOf("ref", "a", "b"), ReferrerFollows.take())
        assertEquals(emptyList<String>(), ReferrerFollows.take())
    }

    @Test fun `the step follows the profile on Create an account`() {
        val steps = listOf(WizardStep.WELCOME, WizardStep.RELAY_CHOICE, WizardStep.NOSTR_INTRO, WizardStep.KEY_PASSWORD, WizardStep.PROFILE, WizardStep.COMPLETE)
        assertEquals(
            listOf(WizardStep.WELCOME, WizardStep.RELAY_CHOICE, WizardStep.NOSTR_INTRO, WizardStep.KEY_PASSWORD, WizardStep.PROFILE, WizardStep.REFERRER, WizardStep.COMPLETE),
            withReferrerStep(steps, SetupPath.NEW_TO_NOSTR, readOnly = false),
        )
    }

    @Test fun `the step follows the key on I already use Nostr, unless read-only`() {
        val steps = listOf(WizardStep.WELCOME, WizardStep.RELAY_CHOICE, WizardStep.USE_NOSTR_KEY, WizardStep.RELAY_CHECK, WizardStep.IMPORT_TOUR)
        assertEquals(WizardStep.REFERRER, withReferrerStep(steps, SetupPath.USE_NOSTR, readOnly = false)[3])
        assertFalse(WizardStep.REFERRER in withReferrerStep(steps, SetupPath.USE_NOSTR, readOnly = true))
        assertFalse(WizardStep.REFERRER in withReferrerStep(steps, SetupPath.FULL, readOnly = false))
    }
}
