package com.nostrvault.service

import android.Manifest
import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.core.graphics.drawable.toBitmap
import coil.ImageLoader
import coil.request.ImageRequest
import com.nostrvault.BuildConfig
import com.nostrvault.MainActivity
import com.nostrvault.R
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.BlockedPeople
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.PushPrefs
import com.nostrvault.ui.components.NostrMentions
import com.nostrvault.ui.navigation.NotificationNote
import com.nostrvault.ui.navigation.NotificationTarget
import dagger.Lazy
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
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
 * per-type switches from Settings. While the app is open every kind shows as an
 * in-app pill instead, as on iOS ([deliver]); a pill read there clears its tray
 * entry, and one that goes unread is filed in the tray quietly.
 */
@Singleton
class LocalNotificationService @Inject constructor(
    @ApplicationContext private val context: Context,
    private val configStore: ConfigStore,
    private val nostrService: Lazy<NostrService>,
    private val imageLoader: Lazy<ImageLoader>,
    private val dmService: Lazy<DMService>,
    private val feedService: Lazy<FeedService>,
    private val feedActivityNotifier: Lazy<FeedActivityNotifier>,
) {
    /** Who the folded strangers' alert counts, and how many. */
    data class FoldedFollowers(val members: List<String> = emptyList(), val count: Int = 0) {
        /** Already on screen: an update to it changes the number, silently. */
        val isShowing: Boolean get() = count > 0
    }

    companion object {
        private const val TAG = "LocalNotif"
        private const val MARKER = "🔔NOTIFY|"
        private const val PREVIEW_MARKER = "|preview="
        private const val MAX_SEEN = 500
        /** How long a DM marker waits for the inbox to decrypt its message. */
        private const val DM_OPEN_TIMEOUT_MS = 3_000L
        private const val CARRIED_LOOKUP_TIMEOUT_MS = 1_500L
        // How long an alert waits for its author's name, picture and note (iOS NotificationReadiness).
        private const val AUTHOR_PROFILE_TIMEOUT_MS = 3_000L
        private const val AUTHOR_AVATAR_TIMEOUT_MS = 2_000L
        private const val NOTE_READY_TIMEOUT_MS = 3_000L
        /**
         * The wait while a DM thread is open: a slow decrypt there (Amber) must
         * end with the message appearing in the thread, not a generic alert first.
         */
        private const val DM_OPEN_TIMEOUT_IN_THREAD_MS = 15_000L

        private fun isDm(type: String) = type == "dm" || type == "giftwrap"

        /**
         * Only people in your Web of Trust (or follows) notify. [trusted] empty
         * means the graph has not loaded, and then nobody is held back. Gift
         * wraps carry a throwaway author and the catch-up summary carries none,
         * so they are not judged here. A zap marker's author is the lightning
         * service that signed the receipt, not the zapper; the relay already
         * admitted the receipt by the zapper's own standing (haven-go
         * zapimport.go inboxTrustKey), so it is not judged again. iOS:
         * NotificationPolicy.authorMayNotify. Follows pass as well: they are
         * never dropped for trust, only told differently ([followIsNamed]).
         */
        fun authorMayNotify(author: String, type: String, trusted: Set<String>, own: Set<String>): Boolean {
            if (author.isEmpty() || type == "giftwrap" || type == "summary" || type == "zap" || type == "follow") return true
            if (trusted.isEmpty() || author in own) return true
            return author in trusted
        }

        /**
         * Whether a new follower is announced by name. Only someone in your Web
         * of Trust is; anyone else, and everyone while the graph is empty (a
         * brand-new account), is folded into one nameless "N new followers"
         * alert: a stranger's follow is the cheapest event to forge, so it must
         * not put a chosen name or picture on the lock screen, but you still
         * hear that you gained followers. iOS NotificationPolicy.followIsNamed.
         */
        fun followIsNamed(follower: String, trusted: Set<String>): Boolean = follower in trusted

        /**
         * The folded alert once [follower] joins it. [showing] is the alert
         * still on screen (empty once tapped or cleared, so the count starts
         * over). Only the latest [cap] strangers ride along, so the alert stays
         * small however many follow; they exist to count a repeat once, and the
         * count itself is stored apart from them. iOS NotificationPolicy.foldedFollowers.
         */
        fun foldedFollowers(showing: FoldedFollowers, follower: String, cap: Int = 32): FoldedFollowers {
            val count = maxOf(showing.count, showing.members.size)
            val members = (showing.members.filter { it != follower } + follower).takeLast(cap)
            return FoldedFollowers(members, if (follower in showing.members) count else count + 1)
        }

        /** Title and text of the folded strangers' alert. */
        fun foldedFollowersText(count: Int): Pair<String, String> =
            if (count <= 1) "New follower" to "Someone new followed you. Tap to see your followers."
            else "$count new followers" to "Tap to see your followers"

        private const val FOLDED_FOLLOWERS_KEY = "nv_folded_followers"
        private const val FOLDED_FOLLOWER_COUNT_KEY = "nv_folded_follower_count"
        private const val FOLD_FILED_TIMEOUT_MS = 1_000L
        /** The quiet channel a pill that went unread is filed in: no sound, no heads-up. */
        private const val FILED_CHANNEL_ID = "nv_missed_while_open"

        /** A follower key as the relay marker should carry it: 64 hex characters. */
        fun isPubkeyHex(s: String): Boolean = s.length == 64 && s.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }

        /**
         * Whether a marker may be shown while phone notifications are switched
         * off. Only a DM, and only as the in-app banner while the app is open:
         * that banner is part of the app, not a phone notification, so the
         * switch shouldn't hide it. Everything else stays silent.
         */
        fun allowsWithPushOff(type: String, appInForeground: Boolean): Boolean =
            appInForeground && isDm(type)

        /** Whether [prefs] let a [type] marker through. */
        fun wants(prefs: PushPrefs, type: String, appInForeground: Boolean): Boolean = when (type) {
            "mention" -> prefs.mentions
            "reply" -> prefs.replies
            // A quote of your note is a mention of you, so the Mentions switch governs it.
            "quote" -> prefs.mentions
            "dm", "giftwrap" -> prefs.dms
            "zap" -> prefs.zaps
            "reaction" -> prefs.reactions
            "repost" -> prefs.reposts
            // A named follower, or the folded "N new followers" alert.
            "follow", "followers" -> prefs.follows
            // The catch-up backlog count spans every type, so no per-type
            // preference governs it — but turning all of them off must still
            // silence it. It is also meaningless while the app is open: it
            // announces activity you missed, and you missed nothing.
            "summary" -> prefs.wantsAnything && !appInForeground
            else -> false
        }

        /**
         * Whether a [type] marker shows at all, as a pill or in the tray: the
         * phone-notifications switch (a DM pill excepted, [allowsWithPushOff])
         * and that kind's own switch both have to allow it.
         */
        fun mayShow(type: String, pushOn: Boolean, prefs: PushPrefs, appInForeground: Boolean): Boolean =
            (pushOn || allowsWithPushOff(type, appInForeground)) && wants(prefs, type, appInForeground)

        /**
         * The relay hands over the note's raw text, so a mention would read
         * `nostr:npub1…`. Show `@name` instead, the way the feed does. A
         * reaction's preview is its emoji, not note text.
         */
        fun notePreview(type: String, preview: String, profiles: Map<String, FeedProfile>): String =
            if (type == "reaction") preview else NostrMentions.toPlainText(preview, profiles)

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

    /**
     * True while the app is on screen. Set by MainActivity's onStart/onStop.
     * Going to the background takes the banner showing with it, filed in the
     * tray unless it was read.
     */
    @Volatile var appInForeground: Boolean = false
        set(value) {
            field = value
            if (!value) InAppBannerBus.hostLost()
        }

    /** One tray entry per event, keyed by its id ([NotificationTray]). */
    @SuppressLint("MissingPermission") // postNow checks POST_NOTIFICATIONS before posting
    private val tray = NotificationTray(object : NotificationTray.Platform<Notification> {
        override fun notify(tag: String, id: Int, notification: Notification) =
            NotificationManagerCompat.from(context).notify(tag, id, notification)
        override fun cancel(tag: String, id: Int) = NotificationManagerCompat.from(context).cancel(tag, id)
    })

    init {
        // A banner read in the app takes its tray entry with it; one that went
        // unread is filed there quietly, so it isn't lost. iOS markRead/fileMissed.
        InAppBannerBus.onEnd = { banner, read ->
            if (read) {
                // A folded pill read counts as seen: the next stranger starts over.
                if (banner.folded != null) pillFolded.remove(banner.id)
                tray.markRead(banner.id)
            } else {
                fileMissed(banner)
            }
        }
        InAppBannerBus.onShow = { banner -> tray.unread(banner.id); playPillSound(banner) }
    }

    // Dedup guard. The Go relay only logs NOTIFY for genuinely new events (it
    // skips duplicates before publishing), but a service restart could re-emit;
    // this keeps the most recent event ids to be safe.
    private val seen: MutableSet<String> = Collections.synchronizedSet(LinkedHashSet())

    // Off the poll loop: avatar fetches + posting run here so the relay log
    // poller is never blocked on network I/O.
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** A bundled sound as a URI a channel or ringtone can play. */
    fun soundUri(sound: NotificationSound): Uri =
        Uri.parse("android.resource://${context.packageName}/${sound.resId}")

    /**
     * Create the picked sound's channel and retire every other events channel
     * (idempotent, safe to call repeatedly; called again when the sound
     * changes). A channel's sound is frozen at creation, so a new sound is a
     * new channel: it copies the settings the user gave the channel it replaces
     * (importance, vibration, lock screen), then that one is deleted.
     * Returns the channel to post through.
     */
    @Synchronized
    fun ensureChannel(): String {
        val sound = NotificationSound.fromName(configStore.config.value.notificationSoundName)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return sound.channelId
        val mgr = context.getSystemService(SystemNotificationManager::class.java) ?: return sound.channelId
        val existing = mgr.notificationChannels.map { it.id }.toSet()
        if (sound.channelId !in existing) {
            val previous = NotificationSound.settingsSource(sound, existing)
                ?.let { mgr.getNotificationChannel(it) }
            val channel = NotificationChannel(
                sound.channelId,
                "Mentions & messages",
                previous?.importance ?: SystemNotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Mentions, replies, DMs, zaps, reactions, reposts, and new followers"
                enableVibration(previous?.shouldVibrate() ?: true)
                previous?.vibrationPattern?.let { vibrationPattern = it }
                previous?.let {
                    lockscreenVisibility = it.lockscreenVisibility
                    setShowBadge(it.canShowBadge())
                    enableLights(it.shouldShowLights())
                }
                val attrs = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
                setSound(soundUri(sound), attrs)
            }
            mgr.createNotificationChannel(channel)
        }
        // Retire the rest so Settings shows one events channel, not a stale duplicate.
        for (id in NotificationSound.retiredChannelIds(sound)) {
            if (id in existing) mgr.deleteNotificationChannel(id)
        }
        return sound.channelId
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
        if (BuildConfig.DEBUG) Log.i(TAG, "marker received: type=$type id=${id.take(8)}")

        if (!markSeen(id)) {
            if (BuildConfig.DEBUG) Log.d(TAG, "skip: duplicate ${id.take(8)}")
            return
        }

        val config = configStore.config.value

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

        if (!mayShow(type, config.enablePushNotifications, prefs, appInForeground)) {
            if (BuildConfig.DEBUG) Log.i(TAG, "skip: '$type' switched off (phone notifications or its own switch)")
            return
        }

        // Nothing from someone this account blocked. A gift wrap's author is a
        // throwaway key; its real sender is checked once it opens (announceDm).
        val blocked = config.blockedFor(npub).mapNotNull { nostrService.get().npubToHex(it) }.toSet()
        if (BlockedPeople.isBlocked(author, blocked)) {
            if (BuildConfig.DEBUG) Log.i(TAG, "skip: '$type' author ${author.take(8)} is blocked")
            return
        }

        // Nothing from outside your Web of Trust: those were the spam alerts.
        val own = setOf(recipientHex, nostrService.get().activeHexPubkey)
        val trusted = trustedAuthors()
        if (!authorMayNotify(author, type, trusted, own)) {
            if (BuildConfig.DEBUG) Log.i(TAG, "skip: '$type' author ${author.take(8)} outside Web of Trust")
            return
        }

        if (isDm(type)) {
            announceDm(id, type, author, recipientHex, npub, blocked)
            return
        }

        // "While you were away" only after a real absence, once per absence (iOS).
        if (type == "summary" && !feedActivityNotifier.get().claimRelaySummary()) {
            if (BuildConfig.DEBUG) Log.i(TAG, "skip: summary, not away 2 h or already announced")
            return
        }

        if (type == "follow") {
            if (followIsNamed(author, trusted)) announceFollow(author, npub) else announceFoldedFollow(author, npub)
            return
        }

        scope.launch {
            // Not before the note and its author can show (iOS NotificationReadiness).
            val carried = withTimeoutOrNull(NOTE_READY_TIMEOUT_MS) {
                var found = carriedNotes(type, id)
                while (NotificationNote.EVENT_EXTRA !in found) { delay(250); found = carriedNotes(type, id) }
                found
            } ?: emptyMap()
            val profile = awaitAuthor(author)
            val shown = notePreview(type, preview, nostrService.get().profiles.value)
            val (title, text) = buildContent(type, profile?.bestName, shown)
            deliver(InAppBanner(id, title, text, type, author, npub, profile?.pictureURL, carried))
        }
    }

    /**
     * Every kind, as on iOS: a pill while the app is open, a system
     * notification otherwise. A pill that goes unread is filed ([fileMissed]).
     */
    private fun deliver(banner: InAppBanner) {
        if (gatheredForReturn(banner)) return
        InAppBannerBus.deliver(banner, { appInForeground }) {
            // Gated when the marker came in, maybe while the app was open: a
            // DM let through as a pill with phone notifications off must not
            // reach the tray because the app left while it decrypted.
            if (mayGoToTray(it)) post(it.id, it.title, it.text, it.type, it.author, it.npub, it.pictureUrl, it.carried)
        }
    }

    /**
     * Just back from the background: one bottom pill and one sound for
     * everything, not a top pill and a sound each ([ReturnPillManager]). True
     * when [banner] was gathered there and needs no pill of its own.
     */
    private fun gatheredForReturn(banner: InAppBanner): Boolean {
        if (!appInForeground) return false
        val createdAt = NotificationNote.decode(banner.carried[NotificationNote.EVENT_EXTRA])?.createdAt?.times(1000)
        return when (ReturnPillManager.gather(banner.type, banner.id, createdAt)) {
            ReturnPillManager.Gathered.FIRST -> { playPillSound(banner); true }
            ReturnPillManager.Gathered.ADDED -> true
            ReturnPillManager.Gathered.NO -> false
        }
    }

    /** The gate again, as a tray entry: phone notifications and the kind's switch, the app behind. */
    private fun mayGoToTray(banner: InAppBanner): Boolean {
        val config = configStore.config.value
        return mayShow(banner.type, config.enablePushNotifications, config.pushPrefsFor(banner.npub), false)
    }

    /**
     * The sound the system notification would have made, with the pill that
     * stands in for it. Only where that notification was allowed (a DM pill
     * with phone notifications off stays silent), and only while the events
     * channel still makes a sound: muting it in system settings mutes this.
     * A folded follower after the first only changes the number, silently.
     */
    private fun playPillSound(banner: InAppBanner) {
        val config = configStore.config.value
        if (!config.enablePushNotifications || !wants(config.pushPrefsFor(banner.npub), banner.type, true)) return
        if ((banner.folded?.count ?: 1) > 1) return
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = context.getSystemService(SystemNotificationManager::class.java)
                ?.getNotificationChannel(ensureChannel())
            if (channel == null || channel.importance < SystemNotificationManager.IMPORTANCE_DEFAULT) return
        }
        val sound = NotificationSound.fromName(config.notificationSoundName)
        try {
            RingtoneManager.getRingtone(context, soundUri(sound))?.apply {
                audioAttributes = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            }?.play()
        } catch (e: Exception) {
            // Best effort: a sound that won't play must not cost the pill.
            Log.w(TAG, "pill sound failed: ${e.message}")
        }
    }

    /**
     * A banner that went unread, filed quietly in the tray so it can still be
     * found: a DM with its generic line only, never the sender or the text.
     * Only where phone notifications would have been allowed: a DM banner
     * also shows with them switched off, and then nothing is filed.
     */
    private fun fileMissed(banner: InAppBanner) {
        if (banner.folded != null) {
            // Filed after any stranger already queued on the lock, so it files
            // the newest count a pill showed, and only if the tray has less.
            scope.launch {
                foldedFollowLock.withLock {
                    val folded = pillFolded.remove(banner.id) ?: return@withLock
                    if (!mayGoToTray(banner)) return@withLock
                    if (foldedFollowersShowing(banner.id).count >= folded.count) return@withLock
                    postFolded(banner.id, banner.npub, folded, filedPill = true)
                }
            }
            return
        }
        if (!mayGoToTray(banner)) return
        val dm = isDm(banner.type)
        post(
            id = banner.id,
            title = InAppBanners.filedTitle(banner.type, banner.title),
            text = InAppBanners.filedText(banner.type, banner.text),
            type = banner.type,
            author = banner.author,
            npub = banner.npub,
            // A filed DM names no one: no sender's picture either.
            pictureUrl = if (dm) null else banner.pictureUrl,
            carried = banner.carried,
            filedPill = true,
        )
    }

    /**
     * The event this notification is about, and for a like, zap or repost the
     * post it was on, as intent extras ([NotificationNote]). Read from this
     * device's relay — the inbox, where the event was stored before the marker
     * was raised, and the outbox, which holds your own posts. The relay is
     * in-process and answers in milliseconds; the timeout only bounds a socket
     * that never does. Empty when it does not answer: the tap then loads by id.
     */
    private suspend fun carriedNotes(type: String, id: String): Map<String, String> {
        val base = configStore.config.value.nostrURL?.trimEnd('/') ?: return emptyMap()
        val routes = listOf(base, "$base/inbox")
        suspend fun lookup(eventId: String) = try {
            nostrService.get()
                .queryRawEvents(listOf("""{"ids":["$eventId"],"limit":1}"""), routes, CARRIED_LOOKUP_TIMEOUT_MS)
                .firstOrNull()
                ?.let(NotificationNote::encode)
        } catch (_: Exception) { null }

        val event = lookup(id) ?: return emptyMap()
        val carried = mutableMapOf(NotificationNote.EVENT_EXTRA to event)
        val parsed = NotificationNote.decode(event) ?: return carried
        if (type == "reaction" || type == "repost" || type == "zap") {
            NotificationTarget.targetNoteId(type, parsed.id, parsed.tags)
                ?.let { lookup(it) }
                ?.let { carried[NotificationNote.TARGET_EXTRA] = it }
        }
        return carried
    }

    /**
     * A new follower is usually a stranger whose profile isn't loaded yet, and
     * "Someone followed you" says nothing — fetch the name first, briefly.
     * Keyed by the follower, not the list event, so a repeat replaces the
     * earlier notification instead of stacking (iOS announceFollow).
     */
    private fun announceFollow(follower: String, npub: String) {
        if (follower.length != 64) return
        scope.launch {
            val profile = awaitAuthor(follower)
            val (title, text) = buildContent("follow", profile?.bestName, "")
            deliver(InAppBanner(follower, title, text, "follow", follower, npub, profile?.pictureURL))
        }
    }

    /**
     * The author's profile once it has loaded, its picture fetched into the
     * image cache, each wait bounded: an alert names a person the app can
     * already draw. Null when the profile never arrives.
     */
    private suspend fun awaitAuthor(pubkey: String): FeedProfile? {
        if (pubkey.length != 64) return null
        val nostr = nostrService.get()
        if (nostr.profiles.value[pubkey] == null) {
            nostr.fetchMissingProfiles(listOf(pubkey))
            withTimeoutOrNull(AUTHOR_PROFILE_TIMEOUT_MS) {
                while (nostr.profiles.value[pubkey] == null) delay(250)
            }
        }
        val profile = nostr.profiles.value[pubkey]
        withTimeoutOrNull(AUTHOR_AVATAR_TIMEOUT_MS) { loadAvatar(profile?.pictureURL) }
        return profile
    }

    /** Serialises the folded alert's read-then-replace, so two strangers arriving together both count. */
    private val foldedFollowLock = Mutex()

    /**
     * The newest count a folded pill showed, until it is filed or read. A
     * stranger arriving between the pill going unread and its filing reaching
     * the tray reads it here, so the count never starts over.
     */
    private val pillFolded = java.util.concurrent.ConcurrentHashMap<String, FoldedFollowers>()

    /**
     * A stranger's follow joins one nameless "N new followers" alert per
     * account ([followIsNamed]). The count and the latest strangers ride in its
     * extras, so the count survives the process, and once the alert is tapped
     * or swiped away the next stranger starts it over. Only the first stranger
     * makes a sound (setOnlyAlertOnce): each later one just changes the number,
     * so a burst of follows buzzes the phone once. iOS announceFoldedFollow.
     */
    private fun announceFoldedFollow(follower: String, npub: String) {
        if (!isPubkeyHex(follower)) return
        scope.launch {
            foldedFollowLock.withLock {
                val id = "followers-$npub"
                val inTray = foldedFollowersShowing(id)
                // While the app is open the count may live only in a pill.
                val showing = listOfNotNull(inTray, pillFolded[id]).maxBy { it.count }
                val folded = foldedFollowers(showing, follower)
                if (!appInForeground) return@withLock postFolded(id, npub, folded)
                val (title, text) = foldedFollowersText(folded.count)
                pillFolded[id] = folded
                val banner = InAppBanner(id, title, text, "followers", "", npub, folded = folded)
                if (gatheredForReturn(banner)) return@withLock
                InAppBannerBus.deliver(banner, { appInForeground }) {
                    scope.launch { foldedFollowLock.withLock { postFolded(id, npub, folded) } }
                }
                // The alert waiting in the tray still counts too, or its
                // number would go backwards after the next stranger.
                // A filed entry stays in the quiet channel.
                if (inTray.isShowing) postFolded(id, npub, folded, filedPill = foldedIsFiled(id))
            }
        }
    }

    /** Posts the folded alert, then waits until the tray lists it so the next stranger's read-back counts it. */
    private suspend fun postFolded(id: String, npub: String, folded: FoldedFollowers, filedPill: Boolean = false) {
        val (title, text) = foldedFollowersText(folded.count)
        postNow(id, title, text, "followers", "", npub, null,
            Bundle().apply {
                putStringArray(FOLDED_FOLLOWERS_KEY, folded.members.toTypedArray())
                putInt(FOLDED_FOLLOWER_COUNT_KEY, folded.count)
            },
            alertOnce = true, filedPill = filedPill)
        awaitFiled(id)
    }

    /**
     * notify() only queues the post; wait (briefly) until the system lists it,
     * so the next stranger's read-back counts this one.
     */
    private suspend fun awaitFiled(id: String) {
        val mgr = context.getSystemService(SystemNotificationManager::class.java) ?: return
        withTimeoutOrNull(FOLD_FILED_TIMEOUT_MS) {
            while (mgr.activeNotifications.none { it.tag == id }) delay(25)
        }
    }

    /** Whether the folded alert in the tray is a filed pill, in the quiet channel. */
    private fun foldedIsFiled(id: String): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val mgr = context.getSystemService(SystemNotificationManager::class.java) ?: return false
        return mgr.activeNotifications.firstOrNull { it.tag == id }?.notification?.channelId == FILED_CHANNEL_ID
    }

    /** What the folded alert still on screen already counts. */
    private fun foldedFollowersShowing(id: String): FoldedFollowers {
        val mgr = context.getSystemService(SystemNotificationManager::class.java) ?: return FoldedFollowers()
        // Before alerts were tagged by event, the folded one was keyed by its hash alone.
        val extras = (mgr.activeNotifications.firstOrNull { it.tag == id }
            ?: mgr.activeNotifications.firstOrNull { it.tag == null && it.id == id.hashCode() })
            ?.notification?.extras ?: return FoldedFollowers()
        val members = extras.getStringArray(FOLDED_FOLLOWERS_KEY)?.toList() ?: emptyList()
        return FoldedFollowers(members, extras.getInt(FOLDED_FOLLOWER_COUNT_KEY, members.size))
    }

    /**
     * A gift wrap is signed by a throwaway key, so its marker cannot say who
     * wrote it — not even when it was you: every DM you send also wraps a copy
     * to yourself, and that copy lands in your own inbox. Skip the copies this
     * device sent, wait for the inbox to decrypt the rest, then show the real
     * sender and text. If it never opens, the generic line still goes out.
     */
    private fun announceDm(id: String, type: String, author: String, recipientHex: String, npub: String, blocked: Set<String>) {
        // A NIP-04 DM names its author in the clear.
        if (author.isNotEmpty() && author.equals(recipientHex, ignoreCase = true)) return
        val dms = dmService.get()
        if (dms.isOwnSentWrap(id)) {
            if (BuildConfig.DEBUG) Log.i(TAG, "skip: own sent DM ${id.take(8)}")
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
                if (BlockedPeople.isBlocked(opened.second.senderPubkey, blocked)) return@launch
                // The conversation is already on screen.
                if (appInForeground && dms.visibleConversation == opened.first) return@launch
            }
            val sender = opened?.second?.senderPubkey ?: author
            val profile = awaitAuthor(sender)
            val profiles = nostrService.get().profiles.value
            val text = opened?.second?.content
                ?.let { dmPreview(NostrMentions.toPlainText(it, profiles)) }.orEmpty()
            val (title, body) = buildContent(type, profile?.bestName, text)
            // Once opened, route as a DM with its counterparty so a tap lands in
            // the thread; an unopened gift wrap still opens the inbox.
            val routeType = if (opened != null) "dm" else type
            val routeAuthor = opened?.first ?: author
            deliver(InAppBanner(id, title, body, routeType, routeAuthor, npub, profile?.pictureURL))
        }
    }

    /**
     * The Relay tab's trusted set: the Web of Trust graph the feeds use plus
     * your follows. Empty until the graph has loaded (a load is started then).
     * iOS: FeedService.relayTabTrustedPubkeys.
     */
    private fun trustedAuthors(): Set<String> {
        val feed = feedService.get()
        val wot = feed.wotPubkeys.value
        if (wot.isEmpty()) {
            feed.loadWotPubkeys()
            return emptySet()
        }
        return wot + feed.followedPubkeys.value
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
            "quote" -> "$who quoted your note" to preview.ifBlank { "Tap to view the quote" }
            "dm", "giftwrap" -> {
                val title = if (name != null) "Message from $who" else "New message"
                title to preview.ifBlank { "You have a new encrypted message" }
            }
            "zap" -> "⚡ New zap" to if (name != null) "$who zapped you" else "You received a zap"
            "reaction" -> "$who reacted ${preview.ifBlank { "❤️" }}" to "Tap to view your note"
            "repost" -> "$who reposted your note" to "Tap to view"
            "follow" -> "$who followed you" to "Tap to see their profile"
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
    private fun post(
        id: String,
        title: String,
        text: String,
        type: String,
        author: String,
        npub: String,
        pictureUrl: String?,
        carried: Map<String, String> = emptyMap(),
        filedPill: Boolean = false,
    ) {
        scope.launch { postNow(id, title, text, type, author, npub, pictureUrl, carried = carried, filedPill = filedPill) }
    }

    /** The quiet channel unread pills are filed in (idempotent). */
    private fun ensureFiledChannel(): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return FILED_CHANNEL_ID
        val mgr = context.getSystemService(SystemNotificationManager::class.java) ?: return FILED_CHANNEL_ID
        if (mgr.getNotificationChannel(FILED_CHANNEL_ID) == null) {
            mgr.createNotificationChannel(
                NotificationChannel(FILED_CHANNEL_ID, "Missed while open", SystemNotificationManager.IMPORTANCE_LOW)
                    .apply { description = "Messages and activity that arrived in the app while you weren't looking" },
            )
        }
        return FILED_CHANNEL_ID
    }

    private suspend fun postNow(
        id: String, title: String, text: String, type: String, author: String, npub: String,
        pictureUrl: String?, extras: Bundle? = null, alertOnce: Boolean = false,
        carried: Map<String, String> = emptyMap(),
        filedPill: Boolean = false,
    ) {
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
            // The post itself, so the tap opens it with nothing to fetch.
            carried.forEach { (key, value) -> putExtra(key, value) }
            // Tells this tap apart from another event's on every API level.
            data = Uri.parse(NotificationTray.tapUri(id))
        }
        val pending = PendingIntent.getActivity(
            context,
            id.hashCode(),
            tapIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        // Fetch the sender's avatar (off the poll loop: callers launch this), then
        // post. Android tints the small icon to a flat silhouette everywhere it
        // appears, reading only alpha, so it has to be ic_notification rather than
        // the full-colour launcher art; the large icon is the sender's profile
        // picture when we have one.
        val largeIcon = loadAvatar(pictureUrl)
        // Resolved after the avatar fetch: a sound picked meanwhile has
        // retired the channel that was current when this started.
        val channelId = if (filedPill) ensureFiledChannel() else ensureChannel()
        val notification = NotificationCompat.Builder(context, channelId)
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
            .apply { if (extras != null) addExtras(extras) }
            .setOnlyAlertOnce(alertOnce)
            .build()

        // One entry per event, so the same event never double-posts.
        if (!tray.post(id, notification, filedPill)) return
        // The folded alert from before tagging, if still up, would sit beside this one.
        if (type == "followers") NotificationManagerCompat.from(context).cancel(id.hashCode())
        if (BuildConfig.DEBUG) Log.i(TAG, "posted notification: \"$title\"")
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
