package com.nostrvault.service

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** One in-app banner: activity that arrived while the app was on screen. */
data class InAppBanner(
    val id: String,
    val title: String,
    val text: String,
    val type: String,
    val author: String,
    val npub: String,
)

/**
 * Hands banners from [LocalNotificationService] (a singleton fed by the relay's
 * log poller) to the Compose host at the top of the app. Holds the newest one;
 * a new banner replaces whatever is showing.
 */
object InAppBannerBus {
    private val _current = MutableStateFlow<InAppBanner?>(null)
    val current: StateFlow<InAppBanner?> = _current

    fun show(banner: InAppBanner) { _current.value = banner }

    /** Clears [id] only if it is still the one showing, so a timer for an older banner can't hide a newer one. */
    fun dismiss(id: String) { _current.compareAndSet(_current.value?.takeIf { it.id == id }, null) }
}
