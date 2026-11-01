package com.nostrvault.service

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Holds off a teardown for [graceMs] after the app goes to the background, so
 * a short trip (answering a message, a glance at another app) comes back to
 * sockets that are still open instead of redialling every relay. Past the
 * grace, [onExpire] runs once.
 */
class PauseGrace(
    private val scope: CoroutineScope,
    private val graceMs: Long,
    private val onExpire: () -> Unit,
) {
    private val lock = Any()
    private var job: Job? = null

    /** The app went to the background: start the grace, unless it is already running. */
    fun pause() {
        synchronized(lock) {
            if (job != null) return
            job = scope.launch {
                delay(graceMs)
                val me = currentCoroutineContext()[Job]
                // Under the lock, so a resume() racing it waits for the
                // teardown and then sees it as done.
                synchronized(lock) {
                    if (job !== me) return@launch
                    job = null
                    onExpire()
                }
            }
        }
    }

    /**
     * The app is back. True when it came back inside the grace: nothing was
     * torn down. False when [onExpire] already ran (or there was no pause).
     */
    fun resume(): Boolean = synchronized(lock) {
        val pending = job ?: return false
        job = null
        pending.cancel()
        true
    }
}
