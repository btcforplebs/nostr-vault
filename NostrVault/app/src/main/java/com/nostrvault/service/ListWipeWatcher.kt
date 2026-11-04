package com.nostrvault.service

import android.Manifest
import android.app.NotificationChannel
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.nostrvault.R
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.di.ApplicationScope
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.ui.screens.settings.listbackup.ListBackupFormat
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import javax.inject.Inject
import javax.inject.Singleton

/**
 * The wipe alarm's watcher (docs/LIST_WIPE_ALARM.md). The vault logs
 * `🔔NOTIFY|type=listversion|…` when it files a new version of an owner's list;
 * that marker comes here instead of the inbox notifier and the unread counts
 * ([isMarker], RelayForegroundService). The app coming to the front checks too.
 * Each check reads that account's list history, runs [ListWipeAlarmRule] and
 * posts one notification per new alarm. It never restores or publishes
 * anything: the banner's buttons do, after a tap.
 */
@Singleton
class ListWipeWatcher @Inject constructor(
    @ApplicationContext private val context: Context,
    private val configStore: ConfigStore,
    private val backups: ListBackupService,
    @ApplicationScope private val scope: CoroutineScope,
) {
    private val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private val mutex = Mutex()

    /** A list-version marker from the vault: check that account. */
    fun onLogLine(raw: String) {
        val author = authorOf(raw) ?: return
        scope.launch { check(author) }
    }

    /** The app came to the front: check every account on this device once the vault answers. */
    fun onForeground() {
        scope.launch {
            withTimeoutOrNull(30_000) { RelayForegroundService.readyForConnections.first { it } } ?: return@launch
            val accounts = configStore.config.value.allAccountNpubs()
                .mapNotNull { npub -> runCatching { com.nostrvault.relay.HavenBridge.decodeNpub(npub) }.getOrNull() }
                .ifEmpty { listOf(configStore.activeAccountHexPubkey.value) }
            for (hex in accounts.distinct()) check(hex)
        }
    }

    private suspend fun check(hex: String) = mutex.withLock {
        if (hex.isEmpty() || !configStore.config.value.hasCompletedSetup) return@withLock
        val active = hex == configStore.activeAccountHexPubkey.value
        val groups = if (active) {
            // The banner reads the same load.
            backups.load()
            backups.groups.value.takeIf { backups.state.value == ListBackupService.State.LOADED }
        } else {
            backups.versionsOf(hex)
        } ?: return@withLock
        val alarms = ListWipeAlarmRule.alarms(groups, OwnListEdits.ids(), backups.dismissed.value)
        val notified = prefs.getStringSet(NOTIFIED, emptySet()).orEmpty()
        // A notification is about a change that just happened; an old one stays on the banner only.
        val since = System.currentTimeMillis() / 1000 - NOTIFY_MAX_AGE_S
        val fresh = alarms.filter { it.second.after.id !in notified && it.second.after.createdAt >= since }
        if (fresh.isEmpty()) return@withLock
        for ((key, alarm) in fresh) post(key, alarm)
        val next = (notified + fresh.map { it.second.after.id }).toList().takeLast(KEEP_NOTIFIED).toSet()
        prefs.edit().putStringSet(NOTIFIED, next).apply()
    }

    private fun post(key: ListHistory.Key, alarm: ListWipeAlarmRule.Alarm) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) return
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return
        val name = ListBackupFormat.title(key).lowercase()
        // The Vault tab's relay half, where the banner with Recover and Merge is.
        val tap = Intent(Intent.ACTION_VIEW, Uri.parse("nostrvault://relay")).apply {
            setPackage(context.packageName)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pending = PendingIntent.getActivity(
            context, alarm.after.id.hashCode(), tap, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val n = NotificationCompat.Builder(context, ensureChannel())
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(ListWipeAlarmText.notificationTitle(alarm, name))
            .setContentText(ListWipeAlarmText.notificationBody(alarm))
            .setStyle(NotificationCompat.BigTextStyle().bigText(ListWipeAlarmText.notificationBody(alarm)))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setAutoCancel(true)
            .setContentIntent(pending)
            .build()
        try {
            NotificationManagerCompat.from(context).notify(TAG_NOTIFICATION, alarm.after.id.hashCode(), n)
        } catch (e: SecurityException) {
            Log.w(TAG, "wipe alarm not posted: ${e.message}")
        }
    }

    private fun ensureChannel(): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val mgr = context.getSystemService(android.app.NotificationManager::class.java)
            if (mgr != null && mgr.getNotificationChannel(CHANNEL_ID) == null) {
                mgr.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, "List safety", android.app.NotificationManager.IMPORTANCE_HIGH).apply {
                        description = "When another app empties or replaces one of your lists"
                    },
                )
            }
        }
        return CHANNEL_ID
    }

    companion object {
        const val PREFS = "list_wipe_alarm"
        private const val NOTIFIED = "notified"
        private const val KEEP_NOTIFIED = 500
        private const val NOTIFY_MAX_AGE_S = 48L * 3600
        private const val CHANNEL_ID = "nv_list_safety"
        private const val TAG_NOTIFICATION = "list_wipe_alarm"
        private const val TAG = "ListWipeWatcher"
        private const val TYPE = "type=listversion|"

        /** Whether [raw] is the vault's list-version nudge rather than an inbox marker. */
        fun isMarker(raw: String): Boolean = raw.contains("🔔NOTIFY|$TYPE")

        /** The author of a list-version marker: 64 lowercase hex, else null. */
        internal fun authorOf(raw: String): String? {
            if (!isMarker(raw)) return null
            val head = raw.substringAfter("🔔NOTIFY|").substringBefore("|preview=")
            val author = head.split('|').firstOrNull { it.startsWith("author=") }?.removePrefix("author=") ?: return null
            return author.takeIf { it.length == 64 && it.all { c -> c in '0'..'9' || c in 'a'..'f' } }
        }
    }
}
