package com.nostrvault.service

import com.nostrvault.ui.notification.PillLane
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.getAndUpdate

/** One in-app banner: activity that arrived while the app was on screen. */
data class InAppBanner(
    val id: String,
    val title: String,
    val text: String,
    val type: String,
    val author: String,
    val npub: String,
) {
    /** The banner's id in the lane ([PillLane]). */
    val laneId: String get() = "activity:$id"
}

/** How an arrival pill left the lane. iOS `NotificationPolicy.PillEnd`. */
enum class PillEnd {
    /** Its lifetime ran out. */
    TIMED_OUT,
    /** A newer arrival took its place. */
    TRIMMED,
    /** The user tapped it. */
    TAPPED,
    /** The app went to the background under it. */
    HOST_LOST,
}

/**
 * The banner showing, and what happens when it goes. Each banner ends exactly
 * once: every way out takes it off [current] atomically, and only the call
 * that did reports the end, so a timer, a tap and a newer banner racing for
 * the same one cannot both file it and mark it read.
 */
open class InAppBanners(private val drawnFor: (laneId: String) -> Long) {
    private val _current = MutableStateFlow<InAppBanner?>(null)
    val current: StateFlow<InAppBanner?> = _current

    /**
     * Told once per banner as it goes: read (tapped, or drawn long enough)
     * or not, and then it is filed in the system tray instead.
     */
    @Volatile var onEnd: ((banner: InAppBanner, read: Boolean) -> Unit)? = null

    /** A new banner replaces whatever is showing; that one ends trimmed. */
    fun show(banner: InAppBanner) {
        _current.getAndUpdate { banner }?.takeIf { it.id != banner.id }?.let { end(it, PillEnd.TRIMMED) }
    }

    /** Ends [id] only if it is still the one showing, so a timer for an older banner can't hide a newer one. */
    fun dismiss(id: String, how: PillEnd) {
        val showing = _current.value?.takeIf { it.id == id } ?: return
        if (_current.compareAndSet(showing, null)) end(showing, how)
    }

    /** The app went to the background: the banner up goes, filed unless it was read. */
    fun hostLost() {
        _current.getAndUpdate { null }?.let { end(it, PillEnd.HOST_LOST) }
    }

    // Asked before the lane lets go of the pill, while it still knows how long it drew.
    private fun end(banner: InAppBanner, how: PillEnd) {
        onEnd?.invoke(banner, !filesPill(how, drawnFor(banner.laneId)))
    }

    companion object {
        /** How long a pill must be on screen before it counts as read, in ms. */
        const val READABLE_AFTER_MS = 1_500L

        /**
         * Whether an arrival pill must be filed in the system tray so it can
         * still be found. The lane draws two pills at most and a newer banner
         * replaces this one, so in a burst one can go unseen or only flash.
         * iOS `NotificationPolicy.filesPill`.
         */
        fun filesPill(how: PillEnd, drawnForMs: Long): Boolean =
            how != PillEnd.TAPPED && drawnForMs < READABLE_AFTER_MS

        /** A filed DM keeps its sender and text in the app: the generic line only. iOS `filedPillTitle`/`filedPillBody`. */
        fun filedTitle(type: String, title: String): String = if (isDm(type)) DM_FILED_TITLE else title
        fun filedText(type: String, text: String): String = if (isDm(type)) DM_FILED_TEXT else text

        private fun isDm(type: String) = type == "dm" || type == "giftwrap"
        const val DM_FILED_TITLE = "New message"
        const val DM_FILED_TEXT = "You have a new encrypted message"
    }
}

/**
 * Hands banners from [LocalNotificationService] (a singleton fed by the relay's
 * log poller) to the Compose host at the top of the app. Holds the newest one.
 */
object InAppBannerBus : InAppBanners(PillLane.shared::drawnFor)
