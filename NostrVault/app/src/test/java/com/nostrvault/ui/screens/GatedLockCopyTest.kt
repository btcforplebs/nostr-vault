package com.nostrvault.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Test

/** The Fanfares lock card's copy, ported from iOS GatedLockCopyTests / GatedArticleBody (before #812). */
class GatedLockCopyTest {
    @Test fun statusFollowsWhatHasBeenPaid() {
        assertEquals("Zap Ann 42 sats to read the full article here.", GatedLockCopy.status("Ann", 42, false, false, null, false))
        assertEquals("Part of the price went through. Zap the rest to unlock.", GatedLockCopy.status("Ann", 42, true, false, null, false))
        assertEquals("You've zapped for this article. If it hasn't opened, the receipt is still on its way.",
            GatedLockCopy.status("Ann", 42, true, true, null, false))
        assertEquals("Paid. Waiting for the author's server to see your zap. This can take a minute or two.",
            GatedLockCopy.status("Ann", 42, true, true, null, true))
        assertEquals("boom", GatedLockCopy.status("Ann", 42, true, true, "boom", true))
    }

    @Test fun theButtonNeverOffersAShareAlreadyPaid() {
        assertEquals("Zap 42 sats to unlock", GatedLockCopy.buttonLabel(42, paid = false, unpaidEmpty = false, dueSats = 42))
        assertEquals("Zap the remaining 4 sats", GatedLockCopy.buttonLabel(10, paid = true, unpaidEmpty = false, dueSats = 4))
        assertEquals("Check again", GatedLockCopy.buttonLabel(10, paid = true, unpaidEmpty = true, dueSats = 0))
    }

    @Test fun confirmNamesTheAuthorOnlyWhenTheyTakeItAll() {
        assertEquals("Zap 42 sats to Ann?", GatedLockCopy.confirmTitle(1, 42, "Ann"))
        assertEquals("Zap 11 sats to unlock?", GatedLockCopy.confirmTitle(2, 11, "Ann"))
    }

    @Test fun aFailureAfterMoneyMayHaveMovedWarnsBeforePayingAgain() {
        assertEquals("No wallet", GatedLockCopy.payFailure(false, "No wallet"))
        assertEquals(
            "The zap may not have gone through (timeout). Check your wallet before paying again — tap Check again if it did.",
            GatedLockCopy.payFailure(true, "timeout"),
        )
    }
}
