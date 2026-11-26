package com.nostrvault.setup

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReferrerFollowGateTest {
    @Test fun needsFiveWhenEnoughAreOffered() {
        assertFalse(ReferrerFollowGate.canFollow(ticked = 0, offered = 40))
        assertFalse(ReferrerFollowGate.canFollow(ticked = 3, offered = 40))
        assertTrue(ReferrerFollowGate.canFollow(ticked = 4, offered = 40))
        assertTrue(ReferrerFollowGate.canFollow(ticked = 9, offered = 40))
        assertFalse(ReferrerFollowGate.offersReferrerOnly(40))
    }

    @Test fun fewerOfferedThanFiveNeedsAllOfThem() {
        assertTrue(ReferrerFollowGate.canFollow(ticked = 0, offered = 0))
        assertFalse(ReferrerFollowGate.canFollow(ticked = 1, offered = 2))
        assertTrue(ReferrerFollowGate.canFollow(ticked = 2, offered = 2))
        assertTrue(ReferrerFollowGate.offersReferrerOnly(3))
        assertFalse(ReferrerFollowGate.offersReferrerOnly(4))
    }

    @Test fun buttonSaysHowManyMore() {
        assertEquals("Pick 4 more people", ReferrerFollowGate.buttonText(ticked = 0, offered = 40))
        assertEquals("Pick 1 more person", ReferrerFollowGate.buttonText(ticked = 3, offered = 40))
        assertEquals("Follow 5 people", ReferrerFollowGate.buttonText(ticked = 4, offered = 40))
        assertEquals("Follow 1 person", ReferrerFollowGate.buttonText(ticked = 0, offered = 0))
    }
}
