package com.nostrvault.relay

import android.content.Context
import android.os.PowerManager
import android.util.Log
import com.nostrvault.relay.RelayForegroundService.Companion.TAG
import com.nostrvault.relay.RelayForegroundService.Companion.WAKELOCK_TAG
import com.nostrvault.relay.RelayForegroundService.LifecycleState

/**
 * When the relay keeps the CPU awake.
 *
 * The foreground service keeps the process alive; the wake lock only stops
 * the CPU from sleeping. That is needed while the relay boots or stops (the
 * databases open and close), and while the FIPS mesh offers this relay to
 * peers, who would otherwise wait for doze's next maintenance window.
 *
 * Serving this phone's own app needs none: the app is on screen when it asks.
 * Held all the time, it kept the CPU out of deep doze all night (5h48m on the
 * Moto, 10-31 to 11-01).
 */
internal object RelayWakeLockPolicy {
    fun shouldHold(state: LifecycleState, servingMesh: Boolean): Boolean = when (state) {
        LifecycleState.BOOTING, LifecycleState.STOPPING -> true
        LifecycleState.RUNNING -> servingMesh
        LifecycleState.IDLE -> false
    }
}

    // ── Wake lock ──────────────────────────────────────────────────

    /** Takes or drops the wake lock to match [RelayWakeLockPolicy]. */
    internal fun RelayForegroundService.syncWakeLock() {
        synchronized(this) {
            if (RelayWakeLockPolicy.shouldHold(lifecycleState, servingMesh)) acquireWakeLock() else releaseWakeLock()
        }
    }

    private fun RelayForegroundService.acquireWakeLock() {
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
        synchronized(this) {
            wakeLock?.let {
                if (it.isHeld) {
                    it.release()
                    Log.d(TAG, "Wake lock released")
                }
            }
            wakeLock = null
        }
    }
