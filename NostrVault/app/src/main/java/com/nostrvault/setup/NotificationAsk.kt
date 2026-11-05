package com.nostrvault.setup

import com.nostrvault.relay.HavenConfig

/**
 * Notifications are asked once, right after setup, once the main screen shows
 * (PLANS/NV_FIRST_RUN_ENTRY_PLAN_2026_11_05.md §4). Setup marks the question
 * pending ([HavenConfig.notificationAskPending]); MainActivity asks and saves
 * the answer. Push stays off until then and is switched on only by a yes.
 * Nothing is asked on a later launch, so an install that was never asked is
 * not asked cold.
 */
object NotificationAsk {
    enum class Action {
        /** Nothing to do: no question pending. */
        NONE,
        /** Show Android's notification question (13+, not yet allowed). */
        ASK,
        /** Already allowed (Android 12 and older, or allowed before): switch push on without asking. */
        ALLOWED,
    }

    fun next(config: HavenConfig, needsPermission: Boolean, granted: Boolean): Action = when {
        !config.hasCompletedSetup || !config.notificationAskPending -> Action.NONE
        needsPermission && !granted -> Action.ASK
        else -> Action.ALLOWED
    }

    /** The answer saved: never asked again, push on only if [granted]. */
    fun answered(config: HavenConfig, granted: Boolean): HavenConfig = config.copy(
        notificationAskPending = false,
        notificationPermissionAsked = true,
        enablePushNotifications = granted,
    )
}
