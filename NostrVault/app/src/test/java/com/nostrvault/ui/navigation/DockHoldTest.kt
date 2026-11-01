package com.nostrvault.ui.navigation

import android.view.HapticFeedbackConstants
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import com.nostrvault.data.model.VaultMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The dock hold-drag-release engine (iOS #1505's numbers). */
class DockHoldTest {

    @Test fun `numbers match iOS`() {
        assertEquals(120L, DockHold.HOLD_MS)
        assertEquals(6f, DockHold.OPEN_SLIDE.value)
        assertEquals(300L, DockHold.TAP_GRACE_MS)
        assertEquals(28f, DockHold.ROW_SLACK_X.value)
        assertEquals(1f, DockHold.ROW_SLACK_Y.value)
        assertEquals(0.94f, DockHold.PRESSED_SCALE)
        assertEquals(1.08f, DockHold.OPEN_SCALE)
    }

    @Test fun `let go before the hold and the slide is a tap`() {
        assertEquals(DockHold.Early.TAP, DockHold.early(released = true, movedPx = 3f, openPx = 18f))
    }

    @Test fun `a slight slide opens the menu at once`() {
        assertEquals(DockHold.Early.OPEN, DockHold.early(released = false, movedPx = 18f, openPx = 18f))
        // Slid and let go in the same frame: still opened, and the release then cancels.
        assertEquals(DockHold.Early.OPEN, DockHold.early(released = true, movedPx = 20f, openPx = 18f))
    }

    @Test fun `still down and barely moved is still waiting`() {
        assertNull(DockHold.early(released = false, movedPx = 17.9f, openPx = 18f))
    }

    @Test fun `haptics - light open, tick per row, confirm on pick`() {
        assertEquals(HapticFeedbackConstants.CONTEXT_CLICK, DockHold.constant(DockHold.Haptic.OPEN, sdk = 35))
        assertEquals(HapticFeedbackConstants.SEGMENT_FREQUENT_TICK, DockHold.constant(DockHold.Haptic.ROW, sdk = 34))
        assertEquals(HapticFeedbackConstants.CLOCK_TICK, DockHold.constant(DockHold.Haptic.ROW, sdk = 33))
        assertEquals(HapticFeedbackConstants.CONFIRM, DockHold.constant(DockHold.Haptic.PICK, sdk = 30))
        assertEquals(HapticFeedbackConstants.CONTEXT_CLICK, DockHold.constant(DockHold.Haptic.PICK, sdk = 29))
    }

    private val rows = mapOf(
        VaultMode.ACTIVITY to Rect(500f, 900f, 920f, 984f),
        VaultMode.NOTES to Rect(500f, 888f, 920f, 896f),
    )

    @Test fun `row hit area widens sideways and by a hair vertically`() {
        assertEquals(VaultMode.ACTIVITY, dockRowAt(rows, Offset(470f, 950f), slackXPx = 56f, slackYPx = 2f))
        assertEquals(VaultMode.ACTIVITY, dockRowAt(rows, Offset(700f, 898.5f), slackXPx = 56f, slackYPx = 2f))
        assertNull(dockRowAt(rows, Offset(400f, 950f), slackXPx = 56f, slackYPx = 2f))
        assertNull(dockRowAt(rows, Offset(700f, 1000f), slackXPx = 56f, slackYPx = 2f))
    }

    @Test fun `a row no longer listed is not picked`() {
        val menu = DockHoldMenu<VaultMode>()
        menu.rowBounds.putAll(rows)
        menu.listed = listOf(VaultMode.NOTES)
        assertNull(menu.itemAt(Offset(700f, 950f), 56f, 2f))
        assertEquals(VaultMode.NOTES, menu.itemAt(Offset(700f, 890f), 56f, 2f))
    }

    @Test fun `a slow tap the hold opened the menu under is still a tap`() {
        assertEquals(true, DockHold.graceTap(heldMs = 200, slid = false, visitedRow = false, onButton = true))
    }

    @Test fun `past the grace, or after a slide, a row, or off the button, it cancels`() {
        assertEquals(false, DockHold.graceTap(heldMs = 300, slid = false, visitedRow = false, onButton = true))
        assertEquals(false, DockHold.graceTap(heldMs = 200, slid = true, visitedRow = false, onButton = true))
        assertEquals(false, DockHold.graceTap(heldMs = 200, slid = false, visitedRow = true, onButton = true))
        assertEquals(false, DockHold.graceTap(heldMs = 200, slid = false, visitedRow = false, onButton = false))
    }

    @Test fun `account rows carry a short npub`() {
        assertEquals("npub1jak…c35y", shortAccountNpub("npub1jak2ysvfyffj8gnas474kdwfclkclz3hehm9mw4dryhf8ett6z6qc8c35y"))
        assertEquals("npub1short", shortAccountNpub("npub1short"))
    }

    @Test fun `the highlight follows rows that move under a still finger`() {
        val menu = DockHoldMenu<VaultMode>()
        menu.listed = listOf(VaultMode.ACTIVITY, VaultMode.NOTES)
        menu.open(Rect.Zero)
        // Mid open-animation: Notes sits under the finger.
        menu.rowPlaced(VaultMode.NOTES, Rect(500f, 900f, 920f, 984f))
        menu.track(Offset(700f, 950f), 56f, 2f)
        assertEquals(VaultMode.NOTES, menu.hovered)
        // Settled: Vault is under it now, and a release there picks Vault.
        menu.rowPlaced(VaultMode.NOTES, Rect(500f, 812f, 920f, 896f))
        menu.rowPlaced(VaultMode.ACTIVITY, Rect(500f, 900f, 920f, 984f))
        assertEquals(VaultMode.ACTIVITY, menu.hovered)
        assertEquals(menu.hovered, menu.itemAt(Offset(700f, 950f), 56f, 2f))
    }

    @Test fun `vault dots - lists and relay together, Likes gone in Zaps Only`() {
        VaultTabPicker.listDots = setOf(VaultMode.NOTES)
        assertEquals(setOf(VaultMode.NOTES, VaultMode.LIKES), VaultTabPicker.news(setOf(VaultMode.LIKES), zapsOnly = false))
        assertEquals(setOf(VaultMode.NOTES), VaultTabPicker.news(setOf(VaultMode.LIKES), zapsOnly = true))
        VaultTabPicker.listDots = emptySet()
    }
}
