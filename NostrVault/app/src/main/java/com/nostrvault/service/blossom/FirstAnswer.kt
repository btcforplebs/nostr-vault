package com.nostrvault.service

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch

/**
 * Runs jobs side by side and hands back the first one that succeeds, without
 * waiting for the others. Port of iOS `FirstAnswer`. The jobs run in [scope],
 * not the caller's, so the rest keep going to the end: a post goes out as soon
 * as one Blossom server has the file while the other servers still get their
 * copy. A server that hangs can no longer hold the post: before, the upload
 * pass awaited every server and posted the first in list order.
 */
object FirstAnswer {
    /**
     * The first non-null result, or null once every job has finished with null.
     * [onLate] sees each result that arrives after the winner; [onAllDone] runs
     * once every job has finished (to delete a file the stragglers were reading).
     */
    suspend fun <T : Any> first(
        scope: CoroutineScope,
        jobs: List<suspend () -> T?>,
        onLate: (Int, T?) -> Unit = { _, _ -> },
        onAllDone: () -> Unit = {},
    ): T? {
        if (jobs.isEmpty()) {
            onAllDone()
            return null
        }
        val results = Channel<Pair<Int, T?>>(Channel.UNLIMITED)
        jobs.forEachIndexed { index, job ->
            scope.launch {
                val result = try { job() } catch (e: Exception) { if (e is kotlinx.coroutines.CancellationException) throw e; null }
                results.send(index to result)
            }
        }
        var remaining = jobs.size
        var winner: T? = null
        while (remaining > 0 && winner == null) {
            winner = results.receive().second
            remaining--
        }
        if (remaining == 0) {
            results.close()
            onAllDone()
        } else {
            // Drain the stragglers in the background, off the post's path.
            scope.launch {
                while (remaining > 0) {
                    val (index, result) = results.receive()
                    remaining--
                    onLate(index, result)
                }
                results.close()
                onAllDone()
            }
        }
        return winner
    }
}
