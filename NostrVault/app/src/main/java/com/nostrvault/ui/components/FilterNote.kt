package com.nostrvault.ui.components

import android.os.SystemClock
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.notification.LocalNotificationManager
import com.nostrvault.ui.notification.NotificationManager
import com.nostrvault.ui.notification.PillSize
import com.nostrvault.ui.notification.PillStyle
import com.nostrvault.ui.notification.PillTone
import com.nostrvault.ui.notification.pillCapsule
import com.nostrvault.ui.theme.Motion
import com.nostrvault.ui.theme.NostrVaultIcons
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.UUID

/**
 * The line a filter tap leaves under the toolbar, in one grammar for every
 * screen: "what it does · current setting [· count]", e.g.
 * "Global · Web of Trust on", "Mentions · on · 214+". A filter turned off
 * keeps its own icon, dimmed, so the "what it does" half still reads. When
 * the line is too long for the screen, the title is what gets cut; the
 * setting and count always show whole. iOS `FilterNote`.
 */
data class FilterNote(
    val icon: ImageVector,
    /** What the button does. The only part that truncates. */
    val title: String,
    /** "setting [· count]", kept whole after the title. */
    val detail: String? = null,
    /** An off setting: the icon and text drop to secondary. */
    val dimmed: Boolean = false,
) {
    /** The whole line, as read out. */
    val text: String get() = detail?.let { "$title · $it" } ?: title

    companion object {
        /** "Title · setting", with an optional count last ("Mentions · on · 18"). */
        fun setting(icon: ImageVector, title: String, setting: String, count: String? = null): FilterNote {
            val parts = listOfNotNull(setting, count?.takeIf { it.isNotEmpty() })
            return FilterNote(icon, title, parts.joinToString(" · "))
        }

        /** A filter turned back off: "Title · off" with the button's own icon. */
        fun off(title: String, icon: ImageVector) = FilterNote(icon, title, "off", dimmed = true)

        /** A filter turned back off, without its icon. */
        @Deprecated(
            "Pass the button's own icon: off(title, icon)",
            ReplaceWith("FilterNote.off(title, NostrVaultIcons.FilterOff)", "com.nostrvault.ui.theme.NostrVaultIcons"),
        )
        fun off(title: String) = FilterNote(NostrVaultIcons.FilterOff, "$title off")
    }
}

/**
 * Holds the showing note and times it, posting it to the lane as feedback
 * under one id per screen. [show] is a tap: the text replaces cleanly and the
 * one 2 s timer restarts. [update] is a late result (a count that landed): it
 * changes the text only while the note is still showing, keeps the time left
 * (raised to a short floor so the count is readable, never past a cap after
 * the tap), and is a no-op once the note has gone, so the pill never pops
 * back and a repeating signal can't pin it. The note goes with its [scope]:
 * leaving the screen hides it at once. iOS `FilterNoteModel`.
 */
@Stable
class FilterNoteState internal constructor(
    private val scope: CoroutineScope,
    private val manager: NotificationManager,
    private val id: String = "filter-note:" + UUID.randomUUID(),
) {
    /** The note this state has up; null once it has gone or another feedback replaced it. */
    val note: FilterNote? get() = shown?.takeIf { manager.isShowing(id) }
    private var shown: FilterNote? by mutableStateOf(null)
    private var fade: Job? = null
    private var shownAt = 0L
    private var hidesAt = 0L

    init {
        // The screen's scope ends with the screen; the pill must not outlive it,
        // or "Mentions · on" sits over the next screen and hides its ambient pills.
        scope.coroutineContext[Job]?.invokeOnCompletion { hide() }
    }

    fun show(note: FilterNote) {
        shown = note
        manager.showFilterNote(id, note)
        shownAt = SystemClock.elapsedRealtime()
        hideAt(shownAt + DURATION_MS)
    }

    fun update(note: FilterNote) {
        if (this.note == null) return
        shown = note
        manager.updateFilterNote(id, note)
        // Keep the time left, extended to the floor, within the cap.
        val floor = minOf(SystemClock.elapsedRealtime() + UPDATE_FLOOR_MS, shownAt + MAX_DURATION_MS)
        if (floor > hidesAt) hideAt(floor)
    }

    fun hide() {
        fade?.cancel()
        fade = null
        shown = null
        manager.dismiss(id)
    }

    private fun hideAt(at: Long) {
        hidesAt = at
        fade?.cancel()
        fade = scope.launch {
            delay(at - SystemClock.elapsedRealtime())
            shown = null
            manager.dismiss(id)
        }
    }

    private companion object {
        /** `show()` gives the pill this long. */
        const val DURATION_MS = 2_000L
        /** `update()` leaves at least this long, so a late count is readable… */
        const val UPDATE_FLOOR_MS = 800L
        /** …but never past this long after `show()`, so a repeating signal cannot pin the pill. */
        const val MAX_DURATION_MS = 6_000L
    }
}

/** A screen's filter note, drawn by the lane ([LocalNotificationManager]). */
@Composable
fun rememberFilterNoteState(): FilterNoteState {
    val scope = rememberCoroutineScope()
    val manager = LocalNotificationManager.current
    return remember(scope, manager) { FilterNoteState(scope, manager) }
}

/**
 * The least width the title keeps once both halves can't fit, as on iOS. In
 * sp, so it follows the font scale and holds the same glyphs at every size;
 * [FilterNoteLine] caps it at half the line, so the detail can never be the
 * half that vanishes on a narrow host.
 */
private val FilterNoteTitleFloor = 72.sp

/**
 * Lays the title and the "· setting · count" detail on one line. When they
 * fit, each takes its natural width. When they don't, the title gives way
 * first, down to [FilterNoteTitleFloor] or its full text, whichever is less;
 * past that the detail is what gets cut. So "Lan… · English, Spanish,
 * Portuguese, German" becomes "Languages · English, Spanish, Portu…", and
 * nothing shrinks to a bare "L". With one child it just hugs it. iOS
 * `FilterNoteLine`.
 */
@Composable
private fun FilterNoteLine(content: @Composable () -> Unit) {
    Layout(content = content) { measurables, constraints ->
        val available = constraints.maxWidth
        val ideal = measurables.map { it.maxIntrinsicWidth(constraints.maxHeight) }
        val widths = if (measurables.size == 2 && available != Constraints.Infinity && ideal.sum() > available) {
            val floor = minOf(ideal[0], FilterNoteTitleFloor.roundToPx(), available / 2)
            val title = minOf(available, maxOf(available - ideal[1], floor))
            listOf(title, maxOf(available - title, 0))
        } else {
            ideal.map { minOf(it, available) }
        }
        val placeables = measurables.mapIndexed { i, m ->
            m.measure(constraints.copy(minWidth = 0, maxWidth = widths[i]))
        }
        val height = placeables.maxOfOrNull { it.height } ?: 0
        layout(placeables.sumOf { it.width }, height) {
            var x = 0
            placeables.forEach { p ->
                p.placeRelative(x, (height - p.height) / 2)
                x += p.width
            }
        }
    }
}

/** The dimmed (off) look, the same on iOS. */
private const val FilterNoteDimmedAlpha = 0.55f

/**
 * The lane's small capsule for a filter note: accent while a filter is on,
 * grey when it was turned off, with the icon and text dimmed. One line that
 * hugs its text up to the lane's width; past that the title is cut with "…"
 * down to [FilterNoteTitleFloor], then the setting and count are cut the
 * same way, so neither half vanishes. Takes no taps. A second tap crossfades
 * the text in place. TalkBack reads each new note, since it's the only text
 * the tap leaves.
 */
@Composable
fun FilterNoteContent(note: FilterNote) {
    AnimatedContent(
        targetState = note,
        transitionSpec = { fadeIn(Motion.fade()) togetherWith fadeOut(Motion.fade()) },
        label = "filterNote",
    ) { shown ->
        val tone = if (shown.dimmed) PillTone.NEUTRAL else PillTone.ACCENT
        val content = if (shown.dimmed) PillStyle.textColor.copy(alpha = FilterNoteDimmedAlpha) else PillStyle.textColor
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(PillStyle.innerGap),
            modifier = Modifier
                .pillCapsule(tone, PillSize.SMALL)
                .semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
        ) {
            Icon(
                imageVector = shown.icon,
                contentDescription = null,
                tint = content,
                modifier = Modifier.size(PillSize.SMALL.icon),
            )
            FilterNoteLine {
                Text(
                    text = shown.title,
                    color = content,
                    fontSize = PillSize.SMALL.font,
                    fontWeight = PillSize.SMALL.weight,
                    maxLines = 1,
                    softWrap = false,
                    overflow = TextOverflow.Ellipsis,
                )
                shown.detail?.let { detail ->
                    Text(
                        text = " · $detail",
                        color = content,
                        fontSize = PillSize.SMALL.font,
                        fontWeight = PillSize.SMALL.weight,
                        maxLines = 1,
                        softWrap = false,
                        // "…" as on iOS; the default clips mid-glyph.
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }
}
