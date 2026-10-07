package com.nostrvault.vaultguide

import com.nostrvault.tutorials.TutorialStatus
import com.nostrvault.tutorials.TutorialStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Same cases as iOS `VaultMeterTests` / `FillYourVaultRuleTests`. */
class VaultMeterTest {
    private val owner = "owner"
    private fun people(n: Int) = (1..n).map { "p$it" }
    private fun meter(n: Int, earned: Boolean = false) = VaultMeter.of(people(n), owner, earned)

    @Test fun ownerIsNotAFollow() {
        val m = VaultMeter.of(listOf(owner, "p1", "p2"), owner, false)
        assertEquals(2, m.count)
        assertEquals(listOf("p1", "p2"), m.recent)
    }

    @Test fun duplicatesAndBlanksCountOnce() {
        assertEquals(2, VaultMeter.of(listOf("p1", "", "p1", "p2"), owner, false).count)
    }

    @Test fun stagesAtFiveAndTen() {
        assertEquals(VaultMeter.Stage.FILLING, meter(4).stage)
        assertEquals(VaultMeter.Stage.FILLED, meter(5).stage)
        assertEquals(VaultMeter.Stage.FILLED, meter(9).stage)
        assertEquals(VaultMeter.Stage.MASTER, meter(10).stage)
        assertEquals(VaultMeter.Stage.MASTER, meter(8, earned = true).stage)
    }

    @Test fun progressText() {
        assertEquals("3 of 5", meter(3).progressText)
        assertEquals("7 of 10", meter(7).progressText)
        assertEquals("10 of 10", meter(14).progressText)
        assertEquals("4/5", meter(4).compactProgressText)
    }

    @Test fun accessibilityText() {
        assertEquals("1 of 5 person followed.", meter(1).accessibilityText)
        assertEquals("4 of 5 people followed.", meter(4).accessibilityText)
        assertEquals("Web of trust built. 10 of 10 people followed.", meter(10).accessibilityText)
    }

    @Test fun recentKeepsTheNewestTen() {
        val m = meter(12)
        assertEquals("p3", m.recent.first())
        assertEquals("p12", m.recent.last())
    }

    @Test fun fiveOrMoreSkipsTheGuide() {
        assertFalse(VaultMeter.skipsGuide(4))
        assertTrue(VaultMeter.skipsGuide(5))
    }

    @Test fun celebrationFiresOncePerAccount() {
        val values = mutableMapOf<String, String>()
        val store = VaultMasterStore(object : TutorialStore {
            override fun getString(key: String) = values[key]
            override fun putString(key: String, value: String?) {
                if (value == null) values.remove(key) else values[key] = value
            }
        })
        assertFalse(store.record(meter(9), owner))
        assertTrue(store.record(meter(10), owner))
        assertFalse(store.record(meter(10), owner))
        assertTrue(store.isEarned(owner))
        assertFalse(store.isEarned("someone-else"))
        assertFalse(store.record(meter(10), ""))
    }

    @Test fun topicLists() {
        assertEquals(20, VaultTopics.starter.toSet().size)
        assertTrue(VaultTopics.more.none { it in VaultTopics.starter })
        assertEquals(VaultTopics.more.size, VaultTopics.more.toSet().size)
        (VaultTopics.starter + VaultTopics.more).forEach { assertEquals(it, VaultTopics.normalize(it)) }
    }

    @Test fun typedHashtagIsNormalised() {
        assertEquals("bitcoin", VaultTopics.normalize("  #Bitcoin "))
        assertEquals("selfhosting", VaultTopics.normalize("##Self Hosting"))
        assertNull(VaultTopics.normalize(" # "))
    }

    private fun act(count: Int, status: TutorialStatus = TutorialStatus.NOT_STARTED, known: Boolean = true,
                    prev: Int? = null, active: Boolean = false) =
        FillYourVaultRule.onFollowsChanged(known, prev, count, status, active)

    @Test fun ruleWaitsForTheFollowList() {
        assertEquals(FillYourVaultRule.Action.NONE, act(0, known = false))
        assertEquals(FillYourVaultRule.Action.NONE, act(300, known = false))
    }

    @Test fun ruleStartsOrFinishesSilently() {
        assertEquals(FillYourVaultRule.Action.START, act(4))
        assertEquals(FillYourVaultRule.Action.FINISH_SILENTLY, act(5))
        assertEquals(FillYourVaultRule.Action.NONE, act(0, TutorialStatus.SKIPPED))
        assertEquals(FillYourVaultRule.Action.NONE, act(300, TutorialStatus.DONE))
    }

    @Test fun ruleWhileShowing() {
        assertEquals(FillYourVaultRule.Action.FINISH, act(5, prev = 4, active = true))
        assertEquals(FillYourVaultRule.Action.NONE, act(4, prev = 3, active = true))
        assertEquals(FillYourVaultRule.Action.NONE, act(7, TutorialStatus.DONE, active = true))
        assertEquals(FillYourVaultRule.Action.NONE, act(8, TutorialStatus.DONE, prev = 7, active = true))
    }

    @Test fun closingByHand() {
        assertEquals(TutorialStatus.SKIPPED, FillYourVaultRule.onClose(2))
        assertEquals(TutorialStatus.DONE, FillYourVaultRule.onClose(7))
    }
}
