package com.nostrvault.data.model

/**
 * When a waiting post ([QueuedMediaPost]) is tried again, and when it stops
 * trying by itself.
 *
 * Each try uploads the whole file to every mirror. A fixed one-minute retry
 * that never gave up turned one photo a server would not take into gigabytes
 * a day on a phone's data plan. Now the wait doubles from one minute up to six
 * hours, the post stops after [MAX_AUTOMATIC_ATTEMPTS], and a server that says
 * no to the file itself (most 4xx) stops it at once. On a metered network a
 * post over [CELLULAR_LIMIT_BYTES] waits for Wi-Fi. Either way the post stays
 * saved and the user can send it again from Settings → Media Servers.
 *
 * The Swift twin is `HavenApp/HavenApp/Models/MediaPostRetry.swift`.
 */
object MediaPostRetry {
    const val FIRST_DELAY_MS = 60_000L
    const val MAX_DELAY_MS = 6 * 60 * 60 * 1000L
    const val MAX_AUTOMATIC_ATTEMPTS = 10
    const val CELLULAR_LIMIT_BYTES = 1_000_000L

    /** The wait after the [attempts]-th try: 1, 2, 4 … minutes, at most six hours. */
    fun delayMs(afterAttempts: Int): Long {
        if (afterAttempts <= 0) return 0
        val doublings = minOf(afterAttempts - 1, 20)
        return minOf(FIRST_DELAY_MS shl doublings, MAX_DELAY_MS)
    }

    /**
     * An HTTP answer that will be the same next time: the server refuses this
     * file (too big, wrong type, payment needed, forbidden). 408 and 429 are
     * the server being busy, so they are worth another try. So is 401: the auth
     * is signed again on every pass, so a signer hiccup or clock skew can clear.
     */
    fun isPermanentRefusal(status: Int): Boolean =
        status in 400..499 && status != 401 && status != 408 && status != 429

    /**
     * True when every mirror answered with a permanent refusal. [statuses] has
     * one entry per mirror that answered with an HTTP code; a mirror that never
     * answered is missing from it and keeps the post going.
     */
    fun allRefused(mirrors: List<String>, statuses: Map<String, Int>): Boolean =
        mirrors.isNotEmpty() && mirrors.all { mirror -> statuses[mirror]?.let(::isPermanentRefusal) == true }
}

/** The post stopped trying by itself and waits for the user. */
val QueuedMediaPost.needsUser: Boolean
    get() = refusedStatus != null || attempts >= MediaPostRetry.MAX_AUTOMATIC_ATTEMPTS

/** Epoch ms of the next automatic try; null when there is none. */
val QueuedMediaPost.nextAttemptAt: Long?
    get() {
        if (needsUser) return null
        val last = lastAttempt ?: return createdAt
        return last + MediaPostRetry.delayMs(attempts)
    }

fun QueuedMediaPost.isDue(nowMs: Long): Boolean = nextAttemptAt?.let { nowMs >= it } ?: false

/**
 * Too big to send on a metered network without being asked. An attachment
 * with no known size counts as big: queued by an older build, it may be a video.
 */
fun QueuedMediaPost.waitsForWifi(metered: Boolean): Boolean =
    metered && pendingMedia.sumOf { it.byteCount ?: (MediaPostRetry.CELLULAR_LIMIT_BYTES + 1) } > MediaPostRetry.CELLULAR_LIMIT_BYTES

/** The user asked to send it again: a fresh start, as if just queued. */
fun QueuedMediaPost.resetForUserRetry(): QueuedMediaPost = copy(attempts = 0, refusedStatus = null)

/** Why a waiting post no longer sends itself, in words for Settings → Media Servers. */
object WaitingPostStopReason {
    fun of(post: QueuedMediaPost): String? = when {
        post.refusedStatus != null ->
            "Stopped: every media server refused this file (HTTP ${post.refusedStatus}). Try sending now, or add another server."
        post.attempts >= MediaPostRetry.MAX_AUTOMATIC_ATTEMPTS ->
            "Stopped after ${post.attempts} tries. Try sending now when a server is back."
        else -> null
    }
}
