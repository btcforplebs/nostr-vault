package com.nostrvault.service.shareportal.handlers

import com.nostrvault.shareportal.ShareAction

/**
 * One action's app half: what the review card does with a claimed
 * [com.nostrvault.shareportal.ShareIntent]. Mirrors SharePortalHandler.swift.
 * Each action has its own `<Action>ShareHandler` file; phase 2 lanes fill in
 * their own and touch nothing else.
 */
interface ShareHandler {
    val action: ShareAction
    /** False: the review card says [notReadyMessage] and offers only Dismiss. */
    val isReady: Boolean
    val notReadyMessage: String get() = NOT_READY

    companion object {
        const val NOT_READY = "Not ready yet. This kind of share is coming in a later update."
    }
}

/** A handler with nothing behind it yet. */
abstract class StubShareHandler(final override val action: ShareAction) : ShareHandler {
    final override val isReady: Boolean = false
}
