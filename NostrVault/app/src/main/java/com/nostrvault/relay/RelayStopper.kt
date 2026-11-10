package com.nostrvault.relay

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Runs the Go relay's stop off the main thread, and makes the next start wait for it.
 *
 * `stopRelay()` takes the Go lifecycle lock, and a booting relay holds that lock for its
 * whole start (opening the databases, waiting out an earlier drain), then the stop itself
 * takes up to ~5 s. A JNI call can't be cancelled, so a timeout around it on the main
 * thread never fired: `RelayForegroundService.onDestroy` froze the UI for as long as Go took.
 *
 * The stop now runs on [scope]; the service's cleanup waits for it there. A start must
 * call [awaitPending] before `startRelay()`: Go serialises the two, so a start that won the
 * lock first would be torn down by the stop still queued behind it.
 */
internal class RelayStopper(
    internal val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
) {
    @Volatile private var pending: Job? = null

    /** Starts [stop] off the caller's thread and returns at once; the job ends when it returns. */
    fun stopAsync(stop: () -> Unit): Job {
        val previous = pending
        val job = scope.launch {
            previous?.join() // two destroys in a row stop in order
            stop()
        }
        pending = job
        return job
    }

    /** Suspends until the last [stopAsync] has returned; returns at once when none is running. */
    suspend fun awaitPending() {
        pending?.join()
    }

    val isStopping: Boolean get() = pending?.isActive == true
}
