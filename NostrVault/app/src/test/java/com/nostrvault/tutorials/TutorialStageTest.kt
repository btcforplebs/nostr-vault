package com.nostrvault.tutorials

import androidx.compose.ui.geometry.Rect
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Where a card goes and what its last button starts (iOS #414). */
class TutorialStageTest {
    private val metrics = TutorialCardPlacement.Metrics(
        maxWidth = 340f,
        margin = 16f,
        ringGap = 10f,
        tailHalfWidth = 11f,
        cornerRadius = 18f,
        noAnchorBottom = 120f,
    )
    private val screenWidth = 400f
    private val screenHeight = 800f

    private fun place(anchor: Rect?) = TutorialCardPlacement(anchor, screenWidth, screenHeight, metrics)

    @After fun reset() {
        TutorialCenter.walletLinked = { false }
    }

    @Test fun anchorInTopHalfPutsCardBelowWithTailOnTop() {
        val anchor = Rect(left = 20f, top = 40f, right = 80f, bottom = 80f)
        val p = place(anchor)
        assertEquals(TutorialCardPlacement.TailEdge.TOP, p.tail?.edge)
        // Card top sits the ring gap under the anchor, whatever its height.
        assertEquals(90f, p.y(cardHeight = 150f))
        assertEquals(90f, p.y(cardHeight = 300f))
    }

    @Test fun anchorInBottomHalfPutsCardAboveWithTailOnBottom() {
        val anchor = Rect(left = 300f, top = 700f, right = 380f, bottom = 740f)
        val p = place(anchor)
        assertEquals(TutorialCardPlacement.TailEdge.BOTTOM, p.tail?.edge)
        // Its bottom stops the ring gap above the anchor, so it never covers it.
        assertEquals(700f - 10f - 150f, p.y(cardHeight = 150f))
    }

    @Test fun cardStaysOnScreenAndTailStillPointsAtAnchor() {
        val anchor = Rect(left = 0f, top = 40f, right = 40f, bottom = 80f)
        val p = place(anchor)
        assertEquals(340f, p.cardWidth)
        // Pushed in to the margin...
        assertEquals(16f, p.x)
        // ...and the tip is as far toward the anchor as the rounded corner allows.
        assertEquals(18f + 11f, p.tail!!.x)
    }

    @Test fun tipSitsUnderAnchorMiddleWhenThereIsRoom() {
        val anchor = Rect(left = 180f, top = 40f, right = 220f, bottom = 80f)
        val p = place(anchor)
        assertEquals(200f, p.x + p.tail!!.x)
    }

    @Test fun narrowScreenShrinksCardToMargins() {
        val p = TutorialCardPlacement(null, 300f, screenHeight, metrics)
        assertEquals(300f - 32f, p.cardWidth)
    }

    @Test fun cardIsKeptInsideAShortStage() {
        // A content-high sheet: below the anchor would run off its bottom.
        val anchor = Rect(left = 20f, top = 60f, right = 380f, bottom = 120f)
        val p = TutorialCardPlacement(anchor, screenWidth, height = 300f, metrics = metrics)
        assertEquals(300f - 200f, p.y(cardHeight = 200f))
        // And never above the top.
        assertEquals(0f, p.y(cardHeight = 400f))
    }

    @Test fun noAnchorIsLowCentredWithoutTail() {
        val p = place(null)
        assertNull(p.tail)
        assertEquals((screenWidth - 340f) / 2, p.x)
        assertEquals(screenHeight - 120f - 150f, p.y(cardHeight = 150f))
    }

    @Test fun nextPassesOverWalletConnectOnceAWalletIsLinked() {
        TutorialCenter.walletLinked = { false }
        assertEquals(TutorialID.WALLET_CONNECT, TutorialCenter.nextAfter(TutorialID.VAULT))
        TutorialCenter.walletLinked = { true }
        assertEquals(TutorialID.POCKET_RELAY, TutorialCenter.nextAfter(TutorialID.VAULT))
        assertEquals(TutorialID.FEEDS, TutorialCenter.nextAfter(TutorialID.FILL_YOUR_VAULT))
        assertNull(TutorialCenter.nextAfter(TutorialID.POCKET_RELAY))
    }

    @Test fun doneAndSkipDoNotRecheckPagesButQuietFinishDoes() {
        val account = "c".repeat(64)
        val before = TutorialCenter.revision.value
        val savesBefore = TutorialCenter.saves.value
        TutorialCenter.replay(TutorialID.FEEDS)
        TutorialCenter.finish(TutorialID.FEEDS, account)
        TutorialCenter.replay(TutorialID.VAULT)
        TutorialCenter.skip(TutorialID.VAULT, account)
        assertEquals(before, TutorialCenter.revision.value)
        // Settings still re-reads both.
        assertEquals(savesBefore + 2, TutorialCenter.saves.value)
        TutorialCenter.finishQuietly(TutorialID.FILL_YOUR_VAULT, account)
        assertEquals(before + 1, TutorialCenter.revision.value)
    }

    @Test fun startNextFinishesTheActiveOneAndStartsTheNext() {
        val account = "d".repeat(64)
        TutorialCenter.replay(TutorialID.VAULT)
        TutorialCenter.startNext(account)
        assertEquals(TutorialID.WALLET_CONNECT, TutorialCenter.active.value)
        assertEquals(0, TutorialCenter.stepIndex.value)
        TutorialCenter.skip(TutorialID.WALLET_CONNECT, account)
        assertNull(TutorialCenter.active.value)
    }
}
