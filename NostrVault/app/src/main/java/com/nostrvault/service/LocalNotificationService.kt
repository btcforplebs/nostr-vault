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
import com.nostrvault.relay.HavenBridge
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
 * per-type switches from Settings. Fires even while the app is foregrounded — the
 * channel's IMPORTANCE_HIGH already makes it a heads-up notification, so this is not
 * just a background push.
 */
@Singleton
class LocalNotificationService @Inject constructor(
    @ApplicationContext private val context: Context,
    private val configStore: ConfigStore,
    private val nostrService: Lazy<NostrService>,
    private val imageLoader: Lazy<ImageLoader>,
    private val dmService: Lazy<DMService>,
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
        /** How long a DM marker waits for the inbox to decrypt its message. */
        private const val DM_OPEN_TIMEOUT_MS = 3_000L
        /**
         * The wait while a DM thread is open: a slow decrypt there (Amber) must
         * end with the message appearing in the thread, not a generic alert first.
         */
        private const val DM_OPEN_TIMEOUT_IN_THREAD_MS = 15_000L

        private fun isDm(type: String) = type == "dm" || type == "giftwrap"

        /**
         * Whether a marker may be shown while phone notifications are switched
         * off. Only a DM, and only as the in-app banner while the app is open:
         * that banner is part of the app, not a phone notification, so the
         * switch shouldn't hide it. Everything else stays silent.
         */
        fun allowsWithPushOff(type: String, appInForeground: Boolean): Boolean =
            appInForeground && isDm(type)

        /**
         * A decrypted DM as notification text: one line, cut to fit. Null when
         * there is nothing to read, so the caller keeps the generic line.
         */
        fun dmPreview(content: String, limit: Int = 160): String? {
            val oneLine = content.trim().split(Regex("\\s+")).joinToString(" ")
            if (oneLine.isEmpty()) return null
            if (oneLine.length <= limit) return oneLine
            return oneLine.take(limit - 1).trimEnd() + "…"
        }
    }

    /** True while the app is on screen. Set by MainActivity's onStart/onStop. */
    @Volatile var appInForeground: Boolean = false

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

        // The catch-up backlog "summary" marker has no per-event id (it isn't
        // one event) — synthesize one so it isn't rejected by the empty-id
        // check that every other type relies on for dedup.
        val rawId = fields["id"].orEmpty()
        if (type != "summary" && rawId.isEmpty()) return
        val id = rawId.ifEmpty { "summary-${System.currentTimeMillis()}" }
        Log.i(TAG, "marker received: type=$type id=${id.take(8)}")

        if (!markSeen(id)) {
            Log.d(TAG, "skip: duplicate ${id.take(8)}")
            return
        }

        val config = configStore.config.value
        if (!config.enablePushNotifications && !allowsWithPushOff(type, appInForeground)) {
            Log.i(TAG, "skip: enablePushNotifications is OFF (turn it on in Settings → Notifications)")
            return
        }

        // The inbox is shared across every whitelisted account on this device, so the
        // marker's `recipient` (the whitelisted hex pubkey it was actually tagged for —
        // see haven-go's classifyInboxEvent) tells us whose prefs to check. Falling back
        // to whichever account happens to be active in the UI would apply the wrong
        // account's settings whenever the event isn't for the currently-active one.
        val recipientHex = fields["recipient"].orEmpty()
        val npub = recipientHex.takeIf { it.isNotEmpty() }
            ?.let { HavenBridge.hexToNpub(it) }
            ?: config.activeOrOwnerNpub()
        val prefs = config.pushPrefsFor(npub)

        val allowed = when (type) {
            "mention" -> prefs.mentions
            "reply" -> prefs.replies
            "dm", "giftwrap" -> prefs.dms
            "zap" -> prefs.zaps
            "reaction" -> prefs.reactions
            "repost" -> prefs.reposts
            // The catch-up backlog count spans every type, so no per-type
            // preference governs it — but turning all of them off must still
            // silence it. It is also meaningless while the app is open: it
            // announces activity you missed, and you missed nothing.
            "summary" -> prefs.wantsAnything && !appInForeground
            else -> false
        }
        if (!allowed) {
            Log.i(TAG, "skip: '$type' disabled in per-account prefs")
            return
        }

        if (isDm(type)) {
            announceDm(id, type, author, recipientHex, npub)
            return
        }

        val profile = if (author.length == 64) nostrService.get().profiles.value[author] else null
        val (title, text) = buildContent(type, profile?.bestName, preview)
        post(id, title, text, type, author, npub, profile?.pictureURL)
    }

    /**
     * A gift wrap is signed by a throwaway key, so its marker cannot say who
     * wrote it — not even when it was you: every DM you send also wraps a copy
     * to yourself, and that copy lands in your own inbox. Skip the copies this
     * device sent, wait for the inbox to decrypt the rest, then show the real
     * sender and text. If it never opens, the generic line still goes out.
     */
    private fun announceDm(id: String, type: String, author: String, recipientHex: String, npub: String) {
        // A NIP-04 DM names its author in the clear.
        if (author.isNotEmpty() && author.equals(recipientHex, ignoreCase = true)) return
        val dms = dmService.get()
        if (dms.isOwnSentWrap(id)) {
            Log.i(TAG, "skip: own sent DM ${id.take(8)}")
            return
        }
        scope.launch {
            val inThread = appInForeground && dms.visibleConversation != null
            val opened = dms.awaitOpenedMessage(
                id,
                if (inThread) DM_OPEN_TIMEOUT_IN_THREAD_MS else DM_OPEN_TIMEOUT_MS,
            )
            if (opened != null) {
                if (opened.second.isFromMe) return@launch
                // The conversation is already on screen.
                if (appInForeground && dms.visibleConversation == opened.first) return@launch
            }
            val sender = opened?.second?.senderPubkey ?: author
            val profile = if (sender.length == 64) nostrService.get().profiles.value[sender] else null
            val text = opened?.second?.content?.let { dmPreview(it) }.orEmpty()
            val (title, body) = buildContent(type, profile?.bestName, text)
            // Once opened, route as a DM with its counterparty so a tap lands in
            // the thread; an unopened gift wrap still opens the inbox.
            val routeType = if (opened != null) "dm" else type
            val routeAuthor = opened?.first ?: author
            // A DM while the app is open shows the in-app banner instead of a
            // system notification, as on iOS.
            if (appInForeground) {
                InAppBannerBus.show(InAppBanner(id, title, body, routeType, routeAuthor, npub))
            } else {
                post(id, title, body, routeType, routeAuthor, npub, profile?.pictureURL)
            }
        }
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
                title to preview.ifBlank { "You have a new encrypted message" }
            }
            "zap" -> "⚡ New zap" to if (name != null) "$who zapped you" else "You received a zap"
            "reaction" -> "$who reacted ${preview.ifBlank { "❤️" }}" to "Tap to view your note"
            "repost" -> "$who reposted your note" to "Tap to view"
            "summary" -> "Catching up" to preview.ifBlank { "New activity while you were away" }
            else -> "New activity" to "Tap to view"
        }
    }

    /**
     * "N new notes in your feed" from [FeedActivityNotifier]. Tapping it opens
     * the feed (the "summary" type has no event). iOS showFeedNotification.
     */
    fun postFeedSummary(newCount: Int) {
        val title = if (newCount == 1) "New note in your feed" else "$newCount new notes in your feed"
        post(
            id = "feed-summary-${System.currentTimeMillis() / 1000}",
            title = title,
            text = "People you follow posted while you were away.",
            type = "summary",
            author = "",
            npub = "",
            pictureUrl = null,
        )
    }

    @SuppressLint("MissingPermission") // guarded by the runtime check below
    private fun post(id: String, title: String, text: String, type: String, author: String, npub: String, pictureUrl: String?) {
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
            // The notifying event's own id. For a reaction, repost or zap that is
            // the kind 7/6/9735 event, not the post it is about — the marker
            // carries no tags, so the Relay tab resolves the post from the
            // stored event on tap (DeepLinkRouter.fromNotification).
            putExtra("notif_event_id", id)
            putExtra("notif_author", author)
            // The account it arrived for; the nav host switches to it on tap.
            putExtra("notif_npub", npub)
        }
        val pending = PendingIntent.getActivity(
            context,
            id.hashCode(),
            tapIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        // Fetch the sender's avatar off the poll loop, then post. Android tints the
        // small icon to a flat silhouette everywhere it appears, reading only alpha,
        // so it has to be ic_notification rather than the full-colour launcher art;
        // the large icon is the sender's profile picture when we have one.
        scope.launch {
            val largeIcon = loadAvatar(pictureUrl)
            val notification = NotificationCompat.Builder(context, CHANNEL_ID)
                // Status-bar icons are drawn from alpha only, so use the
                // purpose-built 24dp silhouette rather than the full-colour
                // foreground, which flattens to a solid blob.
                .setSmallIcon(R.drawable.ic_notification)
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
