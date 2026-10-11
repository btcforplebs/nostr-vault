package com.nostrvault.ui.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
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
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
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
 * The line a filter tap leaves under the toolbar: the filter's icon and what
 * it did ("Mentions · 18", "Mentions off"). Icon-only filters say what you
 * picked here instead of beside the icon. iOS `FilterNote`.
 */
data class FilterNote(val icon: ImageVector, val text: String) {
    companion object {
        /** A filter turned back off. */
        fun off(title: String) = FilterNote(NostrVaultIcons.FilterOff, "$title off")
    }
}

/**
 * Holds the showing note. A new one replaces the last; each goes after 2 s.
 * iOS `FilterNoteModel`.
 */
@Stable
class FilterNoteState internal constructor(private val scope: CoroutineScope) {
    var note: FilterNote? by mutableStateOf(null)
        private set
    private var fade: Job? = null

    fun show(note: FilterNote) {
        this.note = note
        fade?.cancel()
        fade = scope.launch {
            delay(2_000)
            this@FilterNoteState.note = null
        }
    }
}

@Composable
fun rememberFilterNoteState(): FilterNoteState {
    val scope = rememberCoroutineScope()
    return remember(scope) { FilterNoteState(scope) }
}

/**
 * The glass capsule for [state]'s note; nothing when none. Takes no taps, so
 * it can sit over the content. TalkBack reads each new note, since it's the
 * only text the tap leaves.
 */
@Composable
fun FilterNotePill(state: FilterNoteState, modifier: Modifier = Modifier) {
    // Kept while fading out, so the text doesn't blank mid-fade.
    var last by remember { mutableStateOf<FilterNote?>(null) }
    state.note?.let { last = it }
    AnimatedVisibility(
        visible = state.note != null,
        enter = if (Motion.isReduced) fadeIn(Motion.fade()) else fadeIn(Motion.fade()) + slideInVertically(Motion.fade()) { -it / 2 },
        exit = fadeOut(Motion.fade()),
        modifier = modifier,
    ) {
        val note = last ?: return@AnimatedVisibility
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(7.dp),
            modifier = Modifier
                .glassPillBackground(isOled = LocalOledMode.current)
                .semantics { liveRegion = LiveRegionMode.Polite }
                .padding(vertical = 7.dp, horizontal = 14.dp),
        ) {
            Icon(
                imageVector = note.icon,
                contentDescription = null,
                tint = LocalNostrVaultColors.current.primary,
                modifier = Modifier.size(14.dp),
            )
            Text(text = note.text, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
        }
    }
}
