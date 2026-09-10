package com.nostrvault.service

import android.Manifest
import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.media.AudioAttributes
import android.net.Uri
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.core.graphics.drawable.toBitmap
import coil.ImageLoader
import coil.request.ImageRequest
import com.nostrvault.MainActivity
import com.nostrvault.R
import com.nostrvault.data.local.ConfigStore
import dagger.Lazy
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.util.Collections
import java.util.LinkedHashSet
import javax.inject.Inject
import javax.inject.Singleton
import android.app.NotificationManager as SystemNotificationManager

/**
 * Raises local Android system notifications for inbound Nostr events, with no
 * remote push server. The embedded Go relay runs 24/7 in [com.nostrvault.relay.RelayForegroundService]
 * and logs a machine-parseable `🔔NOTIFY|...` marker (see haven-go/import.go) for
 * every newly-imported inbox/chat event. The single relay log poller
 * ([com.nostrvault.relay.LogStore]) forwards those lines here via [onLogLine].
 *
 * Gating mirrors the (server-based) iOS push design: the global
 * `enablePushNotifications` master toggle plus the per-account [com.nostrvault.relay.PushPrefs]
 * per-type switches from Settings. Heads-up notifications are suppressed while the
 * app is in the foreground (the in-app relay-activity dot already covers that).
 */
@Singleton
class LocalNotificationService @Inject constructor(
    @ApplicationContext private val context: Context,
    private val configStore: ConfigStore,
    private val nostrService: Lazy<NostrService>,
    private val imageLoader: Lazy<ImageLoader>,
) {
    companion object {
        private const val TAG = "LocalNotif"
        // Bump this id whenever the channel's sound/importance must change — a
        // channel's settings are frozen by Android after first creation, so a new
        // id is the only way an updated custom sound actually takes effect.
        private const val CHANNEL_ID = "nostrvault_events_v2"
        private const val OLD_CHANNEL_ID = "nostrvault_events"
        private const val MARKER = "🔔NOTIFY|"
        private const val PREVIEW_MARKER = "|preview="
        private const val MAX_SEEN = 500

        /**
         * Set from [MainActivity]'s lifecycle. When true, the app is on screen and
         * we skip system notifications to avoid doubling up with the in-app dot.
         */
        @Volatile
        var appInForeground: Boolean = false
    }

    // Dedup guard. The Go relay only logs NOTIFY for genuinely new events (it
    // skips duplicates before publishing), but a service restart could re-emit;
    // this keeps the most recent event ids to be safe.
    private val seen: MutableSet<String> = Collections.synchronizedSet(LinkedHashSet())

    // Off the poll loop: avatar fetches + posting run here so the relay log
    // poller is never blocked on network I/O.
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** Create the notification channel (idempotent). Safe to call repeatedly. */
    fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = context.getSystemService(SystemNotificationManager::class.java) ?: return
        // Retire the pre-custom-sound channel so users don't see a stale duplicate.
        mgr.deleteNotificationChannel(OLD_CHANNEL_ID)
        if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Mentions & messages",
            SystemNotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "Mentions, replies, DMs, zaps, reactions, and reposts"
            enableVibration(true)
            // Use a bundled custom sound if one exists at res/raw/notification.*
            // (mp3/wav/ogg). Resolved by name so the code compiles whether or not
            // the file is present; falls back to the system default otherwise.
            val soundId = context.resources.getIdentifier("notification", "raw", context.packageName)
            if (soundId != 0) {
                val soundUri = Uri.parse("android.resource://${context.packageName}/$soundId")
                val attrs = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
                setSound(soundUri, attrs)
            }
        }
        mgr.createNotificationChannel(channel)
    }

    /**
     * Feed every relay log line here. Only `🔔NOTIFY|...` markers are acted on;
     * everything else is ignored cheaply.
     */
    fun onLogLine(raw: String) {
        val idx = raw.indexOf(MARKER)
        if (idx < 0) return
        handle(raw.substring(idx + MARKER.length))
    }

    private fun handle(body: String) {
        // `preview` is always the LAST field and may contain spaces, so split it off
        // before parsing the simple key=value head fields.
        val pIdx = body.indexOf(PREVIEW_MARKER)
        val head = if (pIdx >= 0) body.substring(0, pIdx) else body
        val preview = if (pIdx >= 0) body.substring(pIdx + PREVIEW_MARKER.length) else ""

        val fields = HashMap<String, String>()
        for (part in head.split("|")) {
            val eq = part.indexOf('=')
            if (eq > 0) fields[part.substring(0, eq)] = part.substring(eq + 1)
        }
        val type = fields["type"] ?: return
        val author = fields["author"].orEmpty()
        val id = fields["id"] ?: return
        if (id.isEmpty()) return
        Log.i(TAG, "marker received: type=$type id=${id.take(8)}")

        if (!markSeen(id)) {
            Log.d(TAG, "skip: duplicate ${id.take(8)}")
            return
        }

        val config = configStore.config.value
        if (!config.enablePushNotifications) {
            Log.i(TAG, "skip: enablePushNotifications is OFF (turn it on in Settings → Notifications)")
            return
        }
        val prefs = config.pushPrefsFor(config.activeOrOwnerNpub())

        val allowed = when (type) {
            "mention" -> prefs.mentions
            "reply" -> prefs.replies
            "dm", "giftwrap" -> prefs.dms
            "zap" -> prefs.zaps
            "reaction" -> prefs.reactions
            "repost" -> prefs.reposts
            else -> false
        }
        if (!allowed) {
            Log.i(TAG, "skip: '$type' disabled in per-account prefs")
            return
        }

        // The in-app dot already signals activity while the app is open.
        if (appInForeground) {
            Log.i(TAG, "skip: app in foreground (in-app dot covers it)")
            return
        }

        val profile = if (author.length == 64) nostrService.get().profiles.value[author] else null
        val (title, text) = buildContent(type, profile?.bestName, preview)
        post(id, title, text, type, author, profile?.pictureURL)
    }

    /** Returns true if this id is newly seen (and records it); false if a duplicate. */
    private fun markSeen(id: String): Boolean = synchronized(seen) {
        if (!seen.add(id)) return false
        if (seen.size > MAX_SEEN) {
            val it = seen.iterator()
            val target = MAX_SEEN / 2
            while (seen.size > target && it.hasNext()) {
                it.next()
                it.remove()
            }
        }
        true
    }

    private fun buildContent(type: String, name: String?, preview: String): Pair<String, String> {
        val who = name ?: "Someone"
        return when (type) {
            "mention" -> "$who mentioned you" to preview.ifBlank { "You were mentioned in a note" }
            "reply" -> "$who replied to your note" to preview.ifBlank { "Tap to view the reply" }
            "dm", "giftwrap" -> {
                val title = if (name != null) "Message from $who" else "New message"
                title to "You have a new encrypted message"
            }
            "zap" -> "⚡ New zap" to if (name != null) "$who zapped you" else "You received a zap"
            "reaction" -> "$who reacted ${preview.ifBlank { "❤️" }}" to "Tap to view your note"
            "repost" -> "$who reposted your note" to "Tap to view"
            else -> "New activity" to "Tap to view"
        }
    }

    @SuppressLint("MissingPermission") // guarded by the runtime check below
    private fun post(id: String, title: String, text: String, type: String, author: String, pictureUrl: String?) {
        ensureChannel()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            Log.w(TAG, "skip: POST_NOTIFICATIONS permission not granted")
            return
        }

        val tapIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("notif_type", type)
            putExtra("notif_event_id", id)
            putExtra("notif_author", author)
        }
        val pending = PendingIntent.getActivity(
            context,
            id.hashCode(),
            tapIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        // Fetch the sender's avatar off the poll loop, then post. The small icon is
        // the app logo (Android masks it to a silhouette on the lockscreen); the
        // large icon is the sender's profile picture when we have one.
        scope.launch {
            val largeIcon = loadAvatar(pictureUrl)
            val notification = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_launcher_foreground)
                .setContentTitle(title)
                .setContentText(text)
                .setStyle(NotificationCompat.BigTextStyle().bigText(text))
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setCategory(NotificationCompat.CATEGORY_SOCIAL)
                .setContentIntent(pending)
                .apply { if (largeIcon != null) setLargeIcon(largeIcon) }
                .build()

            // Stable per-event notification id so the same event never double-posts.
            NotificationManagerCompat.from(context).notify(id.hashCode(), notification)
            Log.i(TAG, "posted notification: \"$title\"")
        }
    }

    /** Load the sender's avatar into a software bitmap via Coil; null on any failure. */
    private suspend fun loadAvatar(url: String?): Bitmap? {
        if (url.isNullOrBlank()) return null
        return try {
            val request = ImageRequest.Builder(context)
                .data(url)
                .allowHardware(false) // notifications need a software bitmap
                .size(128)
                .build()
            imageLoader.get().execute(request).drawable?.toBitmap()
        } catch (e: Exception) {
            Log.w(TAG, "avatar load failed: ${e.message}")
            null
        }
    }
}
