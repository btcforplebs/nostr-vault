package com.nostrvault.relay

import android.os.Process
import android.os.SystemClock
import android.util.Log
import java.util.concurrent.ConcurrentHashMap

/**
 * Cold-start ms marks (Logen 2026-11-14: Vault rows < 0.5 s after a cold
 * tap). Each logs one "⏱ startup <step> +<ms>ms" line, the shape the Go engine
 * and the iPhone write (haven-go startup_marks.go, StartupMarks.swift),
 * counted from when Android started this process. Read them with
 * `adb logcat -s NVStartup`.
 *
 * On Android Go counts its own marks from when the library loaded, so the
 * "go loaded" mark here gives the offset between the two.
 */
object StartupMarks {
    private const val TAG = "NVStartup"
    private val once = ConcurrentHashMap.newKeySet<String>()

    /** Milliseconds since the process started. */
    fun sinceProcessStart(): Long = SystemClock.uptimeMillis() - Process.getStartUptimeMillis()

    /** Logs [step] now. */
    fun mark(step: String) {
        val line = line(step, sinceProcessStart())
        runCatching { Log.i(TAG, line) }
    }

    /** Logs [step] the first time only (a mark that a later launch step would repeat). */
    fun markOnce(step: String) {
        if (once.add(step)) mark(step)
    }

    internal fun line(step: String, ms: Long): String = "⏱ startup $step +${ms}ms"
}
