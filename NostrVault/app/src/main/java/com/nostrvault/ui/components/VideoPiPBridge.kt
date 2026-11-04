package com.nostrvault.ui.components

import android.content.Context
import android.content.ContextWrapper
import android.util.Rational
import com.nostrvault.MainActivity
import androidx.media3.common.Player
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * Connects the video now playing (the full-screen viewer's, or a live stream's)
 * to MainActivity's Picture-in-Picture hooks. The player composable registers
 * itself here; the activity reads [hasActiveVideo]/[aspectRatio] to build PiP
 * params and flips [isInPiP] from onPictureInPictureModeChanged so composables
 * can hide chrome (the nav bar and overlays in NavGraph, everything but the
 * video on the live screen). PiP plan lane C, RESEARCH/NV_PIP_PLAN.md.
 */
object VideoPiPBridge {

    /** True while the activity is displayed in a PiP window. */
    val isInPiP = MutableStateFlow(false)

    private var activePlayer: Player? = null

    /** The active player is the mini player's live stream: closing PiP leaves it playing. */
    private var activeShared = false

    /** A feed video's PiP button opened the viewer: it goes into PiP as soon as its player is up. */
    private var pipOnOpen = false

    var aspectRatio: Rational? = null
        private set

    /** MainActivity hook — refreshes auto-enter PiP params whenever the active video changes. */
    var onActiveVideoChanged: (() -> Unit)? = null

    val hasActiveVideo: Boolean get() = activePlayer != null

    fun setActive(player: Player, shared: Boolean = false) {
        activePlayer = player
        activeShared = shared
        onActiveVideoChanged?.invoke()
    }

    fun updateAspectRatio(width: Int, height: Int) {
        if (width <= 0 || height <= 0) return
        // The platform rejects PiP aspect ratios outside ~0.418–2.39 — clamp extremes.
        val ratio = (width.toFloat() / height.toFloat()).coerceIn(0.42f, 2.38f)
        aspectRatio = Rational((ratio * 10000).toInt(), 10000)
        onActiveVideoChanged?.invoke()
    }

    fun clearActive(player: Player) {
        if (activePlayer === player) {
            activePlayer = null
            activeShared = false
            aspectRatio = null
            onActiveVideoChanged?.invoke()
        }
    }

    /**
     * Called when the PiP window is closed (not expanded) so audio doesn't keep
     * playing. The mini player's live stream carries on (iOS PiPRules).
     */
    fun pauseActive() {
        if (!activeShared) activePlayer?.pause()
    }

    /** A PiP button: the window that [context] belongs to goes into PiP with the active video. */
    fun enter(context: Context) {
        var c: Context? = context
        while (c is ContextWrapper && c !is MainActivity) c = c.baseContext
        (c as? MainActivity)?.enterVideoPiP()
    }

    /** A feed video's PiP button: the viewer it opens enters PiP once its player registers. */
    fun requestPiPOnOpen() {
        pipOnOpen = true
    }

    /** True once, for the player that should enter PiP now ([requestPiPOnOpen]). */
    fun takePiPOnOpen(): Boolean = pipOnOpen.also { pipOnOpen = false }
}
