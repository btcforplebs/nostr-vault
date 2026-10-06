package com.nostrvault.service

import androidx.annotation.RawRes
import com.nostrvault.R

/**
 * Selectable notification sounds (iOS NotificationSound), bundled as [resId].
 * The config stores [displayName], as iOS stores its raw value. The sounds are
 * named through R, not looked up by name: the release build's resource
 * shrinker drops a raw file nothing references.
 *
 * Android freezes a channel's sound when the channel is created, so each sound
 * posts through its own channel ([channelId]); picking another sound moves
 * notifications to that sound's channel and retires the rest.
 */
enum class NotificationSound(val displayName: String, @RawRes val resId: Int) {
    CHIME("Chime", R.raw.chime),
    CONFIDENT("Confident", R.raw.confident),
    JUNTOS("Juntos", R.raw.juntos),
    PING("Ping", R.raw.ping);

    val channelId: String get() = "$CHANNEL_PREFIX${name.lowercase()}"

    companion object {
        val DEFAULT = CHIME

        private const val CHANNEL_PREFIX = "nostrvault_events_"

        /**
         * Channels that came before per-sound ones: the original, and v2 with
         * the single bundled notification.mp3. Retired once a sound channel
         * exists; v2's user settings carry over to it.
         */
        val LEGACY_CHANNEL_IDS = listOf("nostrvault_events_v2", "nostrvault_events")

        /** An unknown or retired name (iOS's old "notification") is the default. */
        fun fromName(name: String?): NotificationSound =
            entries.firstOrNull { it.displayName == name } ?: DEFAULT

        /** Every other events channel, which [selected]'s channel replaces. */
        fun retiredChannelIds(selected: NotificationSound): List<String> =
            entries.filter { it != selected }.map { it.channelId } + LEGACY_CHANNEL_IDS

        /**
         * The channel whose user settings (importance, vibration, lock screen)
         * a newly created [selected] channel copies: the first retired channel
         * that still exists, other sounds before the legacy ones. Null on a
         * fresh install.
         */
        fun settingsSource(selected: NotificationSound, existing: Set<String>): String? =
            retiredChannelIds(selected).firstOrNull { it in existing }
    }
}
