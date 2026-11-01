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
        assertEquals(180L, DockHold.HOLD_MS)
        assertEquals(10f, DockHold.CANCEL_DISTANCE.value)
        assertEquals(28f, DockHold.ROW_SLACK_X.value)
        assertEquals(1f, DockHold.ROW_SLACK_Y.value)
        assertEquals(0.94f, DockHold.PRESSED_SCALE)
        assertEquals(1.08f, DockHold.OPEN_SCALE)
    }

    @Test fun `let go unmoved before the hold is a tap`() {
        assertEquals(DockHold.Early.TAP, DockHold.early(released = true, movedPx = 3f, cancelPx = 30f))
    }

    @Test fun `sliding past the cancel distance before the hold is neither`() {
        assertEquals(DockHold.Early.CANCEL, DockHold.early(released = false, movedPx = 31f, cancelPx = 30f))
        assertEquals(DockHold.Early.CANCEL, DockHold.early(released = true, movedPx = 31f, cancelPx = 30f))
    }

    @Test fun `still down and still is still waiting`() {
        assertNull(DockHold.early(released = false, movedPx = 30f, cancelPx = 30f))
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
        val menu = DockHoldMenu<VaultMode>(alignEnd = true)
        menu.rowBounds.putAll(rows)
        menu.listed = listOf(VaultMode.NOTES)
        assertNull(menu.itemAt(Offset(700f, 950f), 56f, 2f))
        assertEquals(VaultMode.NOTES, menu.itemAt(Offset(700f, 890f), 56f, 2f))
    }

    @Test fun `vault dots - lists and relay together, Likes gone in Zaps Only`() {
        VaultTabPicker.listDots = setOf(VaultMode.NOTES)
        assertEquals(setOf(VaultMode.NOTES, VaultMode.LIKES), VaultTabPicker.news(setOf(VaultMode.LIKES), zapsOnly = false))
        assertEquals(setOf(VaultMode.NOTES), VaultTabPicker.news(setOf(VaultMode.LIKES), zapsOnly = true))
        VaultTabPicker.listDots = emptySet()
    }
}
