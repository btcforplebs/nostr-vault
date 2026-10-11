package com.nostrvault.relay

import android.app.Notification
import android.app.PendingIntent
import android.content.Intent
import androidx.core.app.NotificationCompat
import com.nostrvault.MainActivity
import com.nostrvault.R
import com.nostrvault.relay.RelayForegroundService.Companion.ACTION_STOP
import com.nostrvault.relay.RelayForegroundService.Companion.CHANNEL_ID
import com.nostrvault.relay.RelayForegroundService.Companion.NOTIFICATION_ID
import com.nostrvault.relay.RelayForegroundService.RelayStatus

    // ── Notifications ──────────────────────────────────────────────

    internal fun RelayForegroundService.buildNotification(status: RelayStatus): Notification {
        val statusText = when (status) {
            RelayStatus.BOOTING -> getString(R.string.relay_status_booting)
            RelayStatus.IMPORTING -> getString(R.string.relay_status_importing)
            RelayStatus.RUNNING -> getString(R.string.relay_status_running)
            RelayStatus.OFFLINE -> getString(R.string.relay_status_offline)
        }

        // Open app intent
        val openAppIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        // Stop relay intent
        val stopIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, RelayForegroundService::class.java).apply { action = ACTION_STOP },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(getString(R.string.relay_notification_title))
            .setContentText(statusText)
            .setSmallIcon(R.drawable.ic_notification)
            .setOngoing(true)
            .setShowWhen(false)
            .setSilent(true)
            .setContentIntent(openAppIntent)
            .addAction(android.R.drawable.ic_media_pause, getString(R.string.relay_action_stop), stopIntent)
            .build()
    }

    internal fun RelayForegroundService.updateNotification(status: RelayStatus) {
        val notification = buildNotification(status)
        val manager = getSystemService(android.app.NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, notification)
    }
