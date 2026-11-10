package com.nostrvault.service

import android.app.ActivityManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import kotlinx.serialization.json.Json
import java.io.File
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit

/**
 * Reads the saved feed off the main thread while the app starts, so the
 * first frame can show it.
 *
 * Without this the snapshot was read once the activity had started and then
 * waited for the main thread, which was busy drawing the first frame: that
 * frame was always an empty feed, and the notes came one or more frames later.
 *
 * [start] runs in Application.onCreate, before the config is loaded, so it
 * cannot know which account's snapshot to read: it reads the newest one, the
 * one the last time in the app saved. [take] hands it over only if it is the
 * file the active account asks for; anything else is dropped and the normal
 * restore reads the right file, as before.
 */
internal object FeedSnapshotPreload {
    private const val TAG = "FeedSnapshotPreload"
    private const val PREFIX = "feed_snapshot_"

    /** Unclaimed after this, the read is let go: the process started for something with no screen. */
    private const val KEEP_MS = 10_000L

    private val json = Json { ignoreUnknownKeys = true }

    private class Pending(val file: File, val task: FutureTask<DiskFeedSnapshot?>)

    @Volatile private var pending: Pending? = null

    /** Starts the read when the process is starting for a screen. Main thread, once. */
    fun start(context: Context) {
        if (!startingForAScreen()) return
        val file = newestSnapshot(context.filesDir) ?: return
        val task = FutureTask { decode(file) }
        val p = Pending(file, task)
        pending = p
        Thread(task, "nv-feed-snapshot").start()
        Handler(Looper.getMainLooper()).postDelayed({ if (pending === p) pending = null }, KEEP_MS)
    }

    /**
     * The decoded snapshot if it was read from [file], waiting at most
     * [maxWaitMs] for a read still under way. Null when there is none, it is
     * another account's, it failed, or it is not ready in time. Claimed once.
     */
    fun take(file: File, maxWaitMs: Long): DiskFeedSnapshot? {
        val p = pending ?: return null
        pending = null
        if (p.file.absoluteFile != file.absoluteFile) return null
        return try {
            p.task.get(maxWaitMs, TimeUnit.MILLISECONDS)
        } catch (e: Exception) {
            // Timed out or failed: the normal restore reads it again.
            Log.w(TAG, "Launch snapshot not used: ${e.javaClass.simpleName}")
            null
        }
    }

    internal fun decode(file: File): DiskFeedSnapshot? = try {
        json.decodeFromString(DiskFeedSnapshot.serializer(), file.readText())
    } catch (e: Exception) {
        Log.w(TAG, "Launch snapshot read failed: ${e.message}")
        null
    }

    /** The snapshot written last, which is the account that was on screen. */
    internal fun newestSnapshot(dir: File): File? =
        dir.listFiles { f -> f.isFile && f.name.startsWith(PREFIX) && f.name.endsWith(".json") }
            ?.maxByOrNull { it.lastModified() }

    /**
     * True when the process is coming up to show an activity. A start for the
     * relay service, a widget or a broadcast reads nothing it would not use.
     */
    private fun startingForAScreen(): Boolean {
        val info = ActivityManager.RunningAppProcessInfo()
        ActivityManager.getMyMemoryState(info)
        return info.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
    }
}
