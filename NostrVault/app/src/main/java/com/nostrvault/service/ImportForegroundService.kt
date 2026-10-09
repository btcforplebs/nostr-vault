package com.nostrvault.service

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import com.nostrvault.MainActivity
import com.nostrvault.R
import com.nostrvault.relay.RelayForegroundService

/**
 * Keeps the app alive while [RelayImportService] runs an import. The import
 * stops [RelayForegroundService] first (both need the relay's database), so
 * without this nothing in the foreground covers it: once the app is in the
 * background Android can kill the process mid-import, with the database
 * open. Setup's "Keep it running in the background" relies on it, and so do
 * Settings imports. It does no work itself; [RelayImportService] starts it
 * when an import begins and stops it when the import ends.
 */
class ImportForegroundService : Service() {
    companion object {
        private const val TAG = "ImportForegroundService"
        private const val NOTIFICATION_ID = 1002
        private const val WAKELOCK_TAG = "NostrVault::Import"
        /** Ceiling if the import never reports back, so the battery isn't held forever. */
        private const val WAKELOCK_TIMEOUT_MS = 4 * 60 * 60 * 1000L

        /** Called while the app is in the foreground (the import was just started from the UI). */
        fun start(context: Context) {
            runCatching { context.startForegroundService(Intent(context, ImportForegroundService::class.java)) }
                .onFailure { Log.w(TAG, "Couldn't start: ${it.message}") }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, ImportForegroundService::class.java))
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                buildNotification(),
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0,
            )
        } catch (e: Exception) {
            Log.e(TAG, "startForeground failed: ${e.message}")
            stopSelf()
            return START_NOT_STICKY
        }
        if (wakeLock?.isHeld != true) {
            wakeLock = (getSystemService(Context.POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKELOCK_TAG)
                .apply {
                    setReferenceCounted(false)
                    acquire(WAKELOCK_TIMEOUT_MS)
                }
        }
        // The import lives in this process; if it dies there is nothing to resume.
        return START_NOT_STICKY
    }

    /** Android 15 caps dataSync time; give up the foreground rather than be killed. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.w(TAG, "dataSync time limit reached; the import keeps going without the foreground")
        stopSelf()
    }

    override fun onDestroy() {
        wakeLock?.takeIf { it.isHeld }?.release()
        wakeLock = null
        super.onDestroy()
    }

    private fun buildNotification(): Notification {
        val openApp = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, RelayForegroundService.CHANNEL_ID)
            .setContentTitle(getString(R.string.relay_notification_title))
            .setContentText(getString(R.string.relay_status_importing))
            .setSmallIcon(R.drawable.ic_notification)
            .setOngoing(true)
            .setShowWhen(false)
            .setSilent(true)
            .setProgress(0, 0, true)
            .setContentIntent(openApp)
            .build()
    }
}
