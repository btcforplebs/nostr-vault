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
        assertEquals("Zap 42 sats to unlock", GatedLockCopy.buttonLabel(paid = false, unpaidEmpty = false, dueSats = 42))
        assertEquals("Zap the remaining 4 sats", GatedLockCopy.buttonLabel(paid = true, unpaidEmpty = false, dueSats = 4))
        assertEquals("Check again", GatedLockCopy.buttonLabel(paid = true, unpaidEmpty = true, dueSats = 0))
    }

    @Test fun theButtonNamesWhatItChargesNotTheListedPrice() {
        // A 10-sat price split three ways rounds each share up: 4 + 4 + 4.
        val gated = com.nostrvault.data.model.GatedArticle("x", "https://api.fanfares.live/k", 10,
            com.nostrvault.data.model.GatedArticle.split(10, "a".repeat(64),
                listOf("1", "2", "3").map { listOf("zap", it.repeat(64), "", "1") }))
        assertEquals(12, gated.totalSats)
        assertEquals("Zap 12 sats to unlock", GatedLockCopy.buttonLabel(paid = false, unpaidEmpty = false, dueSats = gated.totalSats))
        assertEquals("Zap Ann 12 sats to read the full article here.", GatedLockCopy.status("Ann", gated.totalSats, false, false, null, false))
    }

    @Test fun confirmNamesTheAuthorOnlyWhenTheyTakeItAll() {
        assertEquals("Zap 42 sats to Ann?", GatedLockCopy.confirmTitle(1, 42, "Ann"))
        assertEquals("Zap 11 sats to unlock?", GatedLockCopy.confirmTitle(2, 11, "Ann"))
    }

    @Test fun aFailureAfterMoneyMayHaveMovedWarnsBeforePayingAgain() {
        assertEquals("No wallet", GatedLockCopy.payFailure(false, "No wallet"))
        assertEquals(
            "The zap may not have gone through (timeout). Check your wallet: if it paid, tap Check again; if not, tap Pay again.",
            GatedLockCopy.payFailure(true, "timeout"),
        )
    }
}
