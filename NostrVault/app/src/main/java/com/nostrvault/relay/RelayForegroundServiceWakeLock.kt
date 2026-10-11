package com.nostrvault.relay

import android.content.Context
import android.os.PowerManager
import android.util.Log
import com.nostrvault.relay.RelayForegroundService.Companion.TAG
import com.nostrvault.relay.RelayForegroundService.Companion.WAKELOCK_TAG

    // ── Wake lock ──────────────────────────────────────────────────

    internal fun RelayForegroundService.acquireWakeLock() {
        if (wakeLock?.isHeld == true) return // already held, avoid double-acquire
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            WAKELOCK_TAG,
        ).apply {
            setReferenceCounted(false)
            // 4-hour ceiling: if the service crashes without calling releaseWakeLock(),
            // the lock auto-releases instead of draining the battery until reboot.
            acquire(4 * 60 * 60 * 1000L)
        }
        Log.d(TAG, "Wake lock acquired (4h timeout)")
    }

    internal fun RelayForegroundService.releaseWakeLock() {
        wakeLock?.let {
            if (it.isHeld) {
                it.release()
                Log.d(TAG, "Wake lock released")
            }
        }
        wakeLock = null
    }
