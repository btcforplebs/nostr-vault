package com.nostrvault.ui.notification

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import com.nostrvault.ui.theme.Motion
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * How important a pill is. The lane shows the most important first; see
 * `docs/pills.md`. Declared most important first, so `ordinal` ranks.
 */
enum class PillLevel {
    /** Something failed. */
    ERROR,
    /** Something you did finished, or something arrived for you. */
    RESULT,
    /** What a button you just tapped did. A new one replaces the old one. */
    FEEDBACK,
    /** Background info (New Posts, a rebuild, an import). Shows only while nothing above it does. */
    AMBIENT,
}

/**
 * The one lane every pill draws in, top-centre under the top bar. Each pill
 * registers while its owner shows it ([PillSlot]); the lane decides which may
 * draw: the two most important, newest first within a level, with only the
 * newest feedback pill, and ambient pills only when nothing else is up.
 * Android counterpart of iOS `PillLane`.
 */
class PillLane(private val now: () -> Long = { System.nanoTime() / 1_000_000 }) {

    private data class Entry(
        val level: PillLevel,
        val since: Long,
        /** When it last started to draw; null while held back. */
        var drawnSince: Long? = null,
        /** How long it drew before that, in ms. */
        var drawnBefore: Long = 0,
    )

    private val lock = Any()
    private val entries = LinkedHashMap<String, Entry>()
    private var clock = 0L

    private val _visible = MutableStateFlow<Set<String>>(emptySet())
    /** The ids that may draw now. */
    val visible: StateFlow<Set<String>> = _visible.asStateFlow()

    private val _hidesAmbient = MutableStateFlow(false)
    /**
     * True while any error, result or feedback pill is drawn. Pills that a
     * screen draws itself (the Feed's New Posts, the WoT rebuild pill) are
     * ambient: hide them while this is true.
     */
    val hidesAmbient: StateFlow<Boolean> = _hidesAmbient.asStateFlow()

    fun enter(id: String, level: PillLevel) = synchronized(lock) {
        if (level == PillLevel.FEEDBACK) {
            // Feedback never stacks: the newest replaces the rest.
            entries.entries.removeAll { it.value.level == PillLevel.FEEDBACK && it.key != id }
        }
        entries[id] = Entry(level, ++clock)
        recompute()
    }

    /**
     * How long [id] has drawn so far in total, in ms; 0 once it has left the
     * lane. Ask before the pill goes. Whether an arrival pill counts as read
     * ([com.nostrvault.service.InAppBanners]). iOS `PillLane.drawnFor`.
     */
    fun drawnFor(id: String): Long = synchronized(lock) {
        val entry = entries[id] ?: return 0
        entry.drawnBefore + (entry.drawnSince?.let { now() - it } ?: 0)
    }

    fun leave(id: String) = synchronized(lock) {
        if (entries.remove(id) != null) recompute()
    }

    private fun recompute() {
        val ranked = entries.entries
            .filter { it.value.level != PillLevel.AMBIENT }
            .sortedWith(compareBy<Map.Entry<String, Entry>> { it.value.level.ordinal }.thenByDescending { it.value.since })
            .take(MAX_VISIBLE)
            .map { it.key }
        val next = ranked.toMutableSet()
        if (next.isEmpty()) {
            entries.entries
                .filter { it.value.level == PillLevel.AMBIENT }
                .maxByOrNull { it.value.since }
                ?.let { next += it.key }
        }
        val hides = next.any { entries[it]?.level != PillLevel.AMBIENT }
        val t = now()
        for ((id, entry) in entries) {
            val since = entry.drawnSince
            if (id in next && since == null) {
                entry.drawnSince = t
            } else if (id !in next && since != null) {
                entry.drawnBefore += t - since
                entry.drawnSince = null
            }
        }
        if (next != _visible.value) _visible.value = next
        if (hides != _hidesAmbient.value) _hidesAmbient.value = hides
    }

    companion object {
        /** The lane the app draws in. */
        val shared = PillLane()
        /** At most this many pills draw at once. */
        const val MAX_VISIBLE = 2
    }
}

/**
 * One pill in the lane: registers [id] at [level] for as long as the slot is
 * in the composition, and draws [content] only while the lane lets it. Takes
 * no room when held back, so a lane column has no spacing of its own and each
 * drawn pill brings its own gap above.
 */
@Composable
fun PillSlot(
    id: String,
    level: PillLevel,
    lane: PillLane = PillLane.shared,
    content: @Composable () -> Unit,
) {
    DisposableEffect(id, level, lane) {
        lane.enter(id, level)
        onDispose { lane.leave(id) }
    }
    val visible by lane.visible.collectAsState()
    val (enter, exit) = Motion.pillTransition
    AnimatedVisibility(visible = id in visible, enter = enter, exit = exit) {
        Box(Modifier.padding(top = PillStyle.gap)) { content() }
    }
}

/** True while the lane shows an error, result or feedback pill: a screen's own ambient pill should hide. */
@Composable
fun rememberHidesAmbient(lane: PillLane = PillLane.shared): Boolean {
    val hides by lane.hidesAmbient.collectAsState()
    return hides
}
