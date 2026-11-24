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

    private fun k(n: Int) = "%064x".format(n)
    private fun keys(picks: List<ReferrerFollows.Pick>) = picks.map { it.pubkey }

    @Test fun `with no mutuals the most-followed among the referrer's follows come first, ties in list order`() {
        val follows = (1..4).map(::k)
        // Nobody follows the referrer (k50) back: k4: 3; k3: 2; k1 and k2: 0.
        val lists = mapOf(k(1) to listOf(k(4), k(3)), k(2) to listOf(k(4), k(3), k(2)), k(3) to listOf(k(4)), k(9) to listOf(k(1), k(1)))
        val ranked = ReferrerFollows.rank(k(50), follows, lists)
        assertEquals(listOf(k(4), k(3), k(1), k(2)), keys(ranked))
        assertEquals(listOf(0, 0, 0, 0), ranked.map { it.close })
    }

    @Test fun `the referrer's close circle outranks fame`() {
        val me = k(50)
        val follows = (1..8).map(::k)
        // k1, k2 follow the referrer back (close); k8 is followed by 4 who aren't.
        val lists = mapOf(
            k(1) to listOf(me, k(7)),
            k(2) to listOf(me, k(7), k(1)),
            k(3) to listOf(k(8)), k(4) to listOf(k(8)), k(5) to listOf(k(8)), k(6) to listOf(k(8)),
        )
        assertEquals(setOf(k(1), k(2)), ReferrerFollows.closeCircle(me, follows, lists))
        val ranked = ReferrerFollows.rank(me, follows, lists)
        assertEquals(listOf(k(7), k(1), k(8)), keys(ranked).take(3))
        assertEquals(2, ranked.first().close)
        assertEquals(0, ranked.first { it.pubkey == k(8) }.close)
    }

    @Test fun `topics are the shared hashtags of the people offered`() {
        val notes = listOf(
            k(1) to listOf(listOf("t", "Photography"), listOf("t", "bitcoin")),
            k(1) to listOf(listOf("t", "photography")), // one person counts once
            k(2) to listOf(listOf("t", "#photography"), listOf("t", "2026")),
            k(3) to listOf(listOf("t", "bitcoin"), listOf("t", "x")), // too short
            k(4) to listOf(listOf("t", "bitcoin")),
            k(9) to listOf(listOf("t", "garden"), listOf("t", "garden")), // not offered
            k(2) to listOf(listOf("t", "garden")), // one person only
        )
        val topics = ReferrerFollows.topics(notes, listOf(k(1), k(2), k(3), k(4)))
        assertEquals(listOf("bitcoin", "photography"), topics.map { it.topic })
        assertEquals(setOf(k(1), k(3), k(4)), topics.first().people)
    }

    @Test fun `skipped people are never offered and the pool is capped`() {
        val ranked = ReferrerFollows.rank(k(999), (1..150).map(::k), emptyMap(), skip = setOf(k(1), k(3)))
        assertEquals(ReferrerFollows.POOL, ranked.size)
        assertEquals(k(2), ranked.first().pubkey)
        assertFalse(k(1) in keys(ranked) || k(3) in keys(ranked))
    }

    @Test fun `who the referrer talks with most comes first, over close circle and fame`() {
        val me = k(50)
        val follows = (1..4).map(::k)
        // k1 is close (follows the referrer back); k4 is the one they talk with most.
        val lists = mapOf(k(1) to listOf(me), k(2) to listOf(k(3)), k(3) to listOf(k(2)))
        val talks = mapOf(k(4) to 9, k(6) to 4)
        val ranked = ReferrerFollows.rank(me, follows, lists, talks = talks, followers = listOf(k(6), k(7), k(1)))
        assertEquals(listOf(k(4), k(6)), keys(ranked).take(2))
        assertEquals(9, ranked.first().talks)
        // A follower is offered, once, after the follows when nothing else ranks them.
        assertEquals(k(7), keys(ranked).last())
        assertEquals(1, keys(ranked).count { it == k(1) })
        assertFalse(ranked.first { it.pubkey == k(6) }.followedByReferrer)
        assertEquals(true, ranked.first { it.pubkey == k(1) }.followedByReferrer)
    }

    @Test fun `talks count replies, reactions and zaps both ways, and zaps the referrer sent`() {
        val ref = k(50)
        fun e(pk: String, kind: Int, vararg tags: List<String>) = com.nostrvault.data.model.TrustMap.Interaction(pk, kind, tags.toList())
        val events = listOf(
            e(ref, 1, listOf("p", k(9)), listOf("p", k(1))), // their reply to k1: 2
            e(ref, 7, listOf("p", k(2))), // their reaction to k2: 2
            e(k(3), 1, listOf("p", ref)), // k3 replied to them: 1
            e(k(99), 9735, listOf("p", ref), listOf("P", k(4))), // k4 zapped them: 3
            e(k(99), 9735, listOf("p", k(5)), listOf("P", ref)), // they zapped k5: 6
        )
        val talks = ReferrerFollows.talks(ref, events)
        assertEquals(mapOf(k(1) to 2, k(2) to 2, k(3) to 1, k(4) to 3, k(5) to 6), talks)
    }

    @Test fun `a follow list is its p tags, hex only, once each`() {
        val a = "a".repeat(64)
        val tags = listOf(listOf("p", a.uppercase()), listOf("p", a), listOf("e", "f".repeat(64)), listOf("p", "short"), listOf("p"))
        assertEquals(listOf(a), ReferrerFollows.follows(tags))
    }

    @Test fun `never the referrer, you, or a repeat`() {
        val picks = ReferrerFollows.rank("ref", listOf("ref", "me", "a", "a", "b"), emptyMap(), skip = setOf("me"))
        assertEquals(listOf("a", "b"), keys(picks))
    }

    @Test fun `picks are taken once, referrer first`() {
        ReferrerFollows.choose("ref", listOf("a", "ref", "b"))
        assertEquals(listOf("ref", "a", "b"), ReferrerFollows.take())
        assertEquals(emptyList<String>(), ReferrerFollows.take())
    }

    @Test fun `the step follows the profile on Create an account`() {
        val steps = listOf(WizardStep.WELCOME, WizardStep.PROFILE, WizardStep.NOSTR_INTRO, WizardStep.KEY_SPARE, WizardStep.KEY_PASSWORD)
        assertEquals(
            listOf(WizardStep.WELCOME, WizardStep.PROFILE, WizardStep.REFERRER, WizardStep.NOSTR_INTRO, WizardStep.KEY_SPARE, WizardStep.KEY_PASSWORD),
            withReferrerStep(steps, SetupPath.NEW_TO_NOSTR),
        )
    }

    @Test fun `only new to Nostr is asked, never I already use Nostr (Logen 2026-11-05)`() {
        val steps = listOf(WizardStep.WELCOME, WizardStep.RELAY_CHOICE, WizardStep.USE_NOSTR_KEY, WizardStep.NEW_TO_VAULT, WizardStep.RELAY_CHECK, WizardStep.IMPORT_TOUR)
        assertEquals(steps, withReferrerStep(steps, SetupPath.USE_NOSTR))
        assertFalse(WizardStep.REFERRER in withReferrerStep(steps, SetupPath.FULL))
    }
}
