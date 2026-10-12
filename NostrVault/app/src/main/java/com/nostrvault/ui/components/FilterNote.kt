package com.nostrvault.ui.components

import android.os.SystemClock
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
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
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.LocalOledMode
import com.nostrvault.ui.theme.Motion
import com.nostrvault.ui.theme.NostrVaultIcons
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

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
 * Holds the showing note. [show] is a tap: the text replaces cleanly and the
 * one 2 s timer restarts. [update] is a late result (a count that landed): it
 * changes the text only while the note is still showing, keeps the time left
 * (raised to a short floor so the count is readable, never past a cap after
 * the tap), and is a no-op once the note has gone, so the pill never pops
 * back and a repeating signal can't pin it. iOS `FilterNoteModel`.
 */
@Stable
class FilterNoteState internal constructor(private val scope: CoroutineScope) {
    var note: FilterNote? by mutableStateOf(null)
        private set
    private var fade: Job? = null
    private var shownAt = 0L
    private var hidesAt = 0L

    fun show(note: FilterNote) {
        this.note = note
        shownAt = SystemClock.elapsedRealtime()
        hideAt(shownAt + DURATION_MS)
    }

    fun update(note: FilterNote) {
        if (this.note == null) return
        this.note = note
        // Keep the time left, extended to the floor, within the cap.
        val floor = minOf(SystemClock.elapsedRealtime() + UPDATE_FLOOR_MS, shownAt + MAX_DURATION_MS)
        if (floor > hidesAt) hideAt(floor)
    }

    fun hide() {
        fade?.cancel()
        fade = null
        note = null
    }

    private fun hideAt(at: Long) {
        hidesAt = at
        fade?.cancel()
        fade = scope.launch {
            delay(at - SystemClock.elapsedRealtime())
            this@FilterNoteState.note = null
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

@Composable
fun rememberFilterNoteState(): FilterNoteState {
    val scope = rememberCoroutineScope()
    return remember(scope) { FilterNoteState(scope) }
}

/** The pill's side margins: it never gets wider than the host minus these. */
private val FilterNoteMargin = 16.dp

/** The dimmed (off) look, the same on iOS. */
private const val FilterNoteDimmedAlpha = 0.55f

/**
 * How far above the host's top edge the pill is drawn, so its top overlaps
 * the bottom of the toolbar glass and its bottom stays above the first post,
 * the same as iOS.
 */
private val FilterNoteRise = 14.dp

/**
 * Hosts a screen's filter note around the [GlassScaffold] content: the pill
 * is drawn at the top centre, raised [FilterNoteRise] above the top of
 * [padding] so it overlaps the bottom of the toolbar and stays above the
 * first post, outside the bar that folds on scroll. Never in the layout
 * flow, so a tap moves nothing; when the list is scrolled it may sit over
 * content, and still takes no taps. Wrap the scaffold's content once per
 * screen, never the toolbar slot.
 */
@Composable
fun FilterNoteHost(
    state: FilterNoteState,
    padding: PaddingValues,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    Box(modifier.fillMaxSize()) {
        content()
        FilterNotePill(
            state,
            Modifier
                .align(Alignment.TopCenter)
                .padding(top = padding.calculateTopPadding())
                .offset(y = -FilterNoteRise),
        )
    }
}

/**
 * The glass capsule for [state]'s note; nothing when none. One line that hugs
 * its text up to the host's width minus [FilterNoteMargin] each side, so it
 * follows the font scale; past that the title is cut with "…" and the setting
 * and count stay whole. Takes no taps, so it can sit over the content. Fades in with a slight scale from its top edge, not a slide from
 * under the bar; Reduce Motion gets the fade alone. A second tap crossfades
 * the text in place. TalkBack reads each new note, since it's the only text
 * the tap leaves.
 */
@Composable
fun FilterNotePill(state: FilterNoteState, modifier: Modifier = Modifier) {
    // Kept while fading out, so the text doesn't blank mid-fade.
    var last by remember { mutableStateOf<FilterNote?>(null) }
    state.note?.let { last = it }
    AnimatedVisibility(
        visible = state.note != null,
        enter = if (Motion.isReduced) fadeIn(Motion.fade())
            else fadeIn(Motion.fade()) + scaleIn(Motion.fade(), initialScale = 0.92f, transformOrigin = TransformOrigin(0.5f, 0f)),
        exit = fadeOut(Motion.fade()),
        modifier = modifier,
    ) {
        val note = last ?: return@AnimatedVisibility
        AnimatedContent(
            targetState = note,
            transitionSpec = { fadeIn(Motion.fade()) togetherWith fadeOut(Motion.fade()) },
            label = "filterNote",
        ) { shown ->
            val tint = if (shown.dimmed) LocalContentColor.current.copy(alpha = FilterNoteDimmedAlpha) else LocalNostrVaultColors.current.primary
            val textColor = if (shown.dimmed) LocalContentColor.current.copy(alpha = FilterNoteDimmedAlpha) else LocalContentColor.current
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(7.dp),
                modifier = Modifier
                    .padding(horizontal = FilterNoteMargin)
                    .glassPillBackground(isOled = LocalOledMode.current)
                    .semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite }
                    // 26 dp tall: fits the gap between the toolbar and the first post.
                    .padding(vertical = 5.dp, horizontal = 14.dp),
            ) {
                Icon(
                    imageVector = shown.icon,
                    contentDescription = null,
                    tint = tint,
                    modifier = Modifier.size(14.dp),
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    // The title gives way: it takes what's left after the detail.
                    Text(
                        text = shown.title,
                        color = textColor,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                    shown.detail?.let { detail ->
                        Text(
                            text = " · $detail",
                            color = textColor,
                            fontSize = 13.sp,
                            fontWeight = FontWeight.SemiBold,
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
}
