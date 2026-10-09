package com.nostrvault.ui.components

import androidx.compose.ui.graphics.TransformOrigin
import com.nostrvault.ui.theme.Motion

/**
 * Where the post just tapped sat on screen, so the thread view can zoom open
 * out of it and close back into it (iOS #306, `.navigationTransition(.zoom)`
 * from the tapped row). Recorded by [NoteCard] on tap and read by the note
 * screen's route transitions; anything older than [MAX_AGE_MS] when the push
 * starts is from some other tap and is ignored (the screen zooms from the
 * middle, as every push does).
 */
object ThreadZoomOrigin {
    private const val MAX_AGE_MS = 1_000L

    @Volatile private var origin: TransformOrigin? = null
    @Volatile private var at = 0L
    /** Per back-stack entry, so closing each thread shrinks into the post it came from. */
    private val byEntry = java.util.concurrent.ConcurrentHashMap<String, TransformOrigin>()

    /** [centerX]/[centerY] in window pixels, [width]/[height] the window's. */
    fun mark(centerX: Float, centerY: Float, width: Int, height: Int) {
        if (width <= 0 || height <= 0) return
        origin = TransformOrigin(
            (centerX / width).coerceIn(0f, 1f),
            (centerY / height).coerceIn(0f, 1f),
        )
        at = System.currentTimeMillis()
    }

    /** The origin for [entryId]'s push, starting now, or null; the fresh mark is consumed. */
    fun take(entryId: String): TransformOrigin? {
        byEntry[entryId]?.let { return it }
        val o = origin?.takeIf { System.currentTimeMillis() - at <= MAX_AGE_MS && !Motion.isReduced }
        origin = null
        if (o != null) byEntry[entryId] = o
        return o
    }

    /** The origin [entryId] opened from, for its close; forgotten after. */
    fun closing(entryId: String): TransformOrigin? = byEntry.remove(entryId)
}
