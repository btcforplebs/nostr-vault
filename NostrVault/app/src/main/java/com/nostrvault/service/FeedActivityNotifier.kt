package com.nostrvault.service

import android.content.Context
import android.util.Log
import com.nostrvault.data.local.ConfigStore
import dagger.Lazy
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import javax.inject.Inject
import javax.inject.Singleton

/**
 * The rules for "N new notes in your feed", ported from iOS
 * NotificationPolicy. One absence of at least two hours produces at most one
 * of these, and it counts notes by their created_at against a watermark of
 * the newest note already seen or announced, so backfilled older notes are
 * never news.
 */
object FeedNotesPolicy {
    /** How long the app must have been away before "while you were away" is true. */
    const val MINIMUM_ABSENCE_SEC = 2 * 60 * 60L

    /**
     * True when [nowSec] falls in an absence long enough to summarise that
     * has not been summarised yet. Never foregrounded: no absence, nothing fires.
     */
    fun shouldAnnounceAbsenceSummary(nowSec: Long, lastForegroundAt: Long?, lastAnnouncedAt: Long?): Boolean {
        if (lastForegroundAt == null) return false
        if (nowSec - lastForegroundAt < MINIMUM_ABSENCE_SEC) return false
        if (lastAnnouncedAt == null) return true
        return lastAnnouncedAt < lastForegroundAt
    }

    /** Notes newer than the watermark; none without a watermark (no baseline yet). */
    fun unannouncedFeedNoteCount(createdAt: List<Long>, lastAnnouncedNoteAt: Long?): Int {
        val cutoff = lastAnnouncedNoteAt ?: return 0
        return createdAt.count { it > cutoff }
    }

    /**
     * Whether a fetched event counts as a feed note under the feed's own
     * switches: kind 1 (replies only with Show Replies on), kind 6 only with
     * Show Reposts on. A reply is a kind 1 with a non-mention "e" tag, as
     * FeedNote reads it.
     */
    fun countsAsFeedNote(kind: Int, tags: List<List<String>>, showReplies: Boolean, showReposts: Boolean): Boolean = when (kind) {
        1 -> showReplies || tags.none { it.size >= 2 && it[0] == "e" && (it.size < 4 || it[3] != "mention") }
        6 -> showReposts
        else -> false
    }
}

/**
 * "New Notes in Your Feed": while the app is away, checks every 15 minutes
 * (iOS's background refresh cadence) whether people you follow posted, and
 * says so once per absence. Android's feed disconnects in the background, so
 * the check asks the feed relays directly instead of reading the feed list.
 * The persisted timestamps play iOS NotificationActivityLog's part.
 */
@Singleton
class FeedActivityNotifier @Inject constructor(
    @ApplicationContext private val context: Context,
    private val configStore: ConfigStore,
    private val nostrService: Lazy<NostrService>,
    private val feedService: Lazy<FeedService>,
    private val localNotificationService: Lazy<LocalNotificationService>,
) {
    companion object {
        private const val TAG = "FeedActivity"
        private const val PREFS = "notify_activity"
        private const val KEY_FOREGROUND = "lastForegroundAt"
        private const val KEY_FEED_SUMMARY = "lastFeedSummaryAt"
        private const val KEY_FEED_NOTE = "lastAnnouncedFeedNoteAt"
        private const val CHECK_INTERVAL_MS = 15 * 60 * 1000L
        private const val AUTHORS_PER_FILTER = 500
    }

    private val prefs by lazy { context.getSharedPreferences(PREFS, Context.MODE_PRIVATE) }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var checkJob: Job? = null

    private fun read(key: String): Long? = prefs.getLong(key, 0L).takeIf { it > 0 }
    private fun store(key: String, value: Long) { prefs.edit().putLong(key, value).apply() }

    /**
     * The user is here, or leaving: either way the feed on screen counts as
     * seen and any absence ends (or starts) now. Call from onStart and onStop.
     */
    fun recordForeground() {
        store(KEY_FOREGROUND, System.currentTimeMillis() / 1000)
        feedService.get().notes.value.maxOfOrNull { it.createdAt.time / 1000 }?.let(::recordAnnouncedFeedNote)
    }

    /** Monotonic: a late older note must not drag the watermark back. */
    private fun recordAnnouncedFeedNote(createdAt: Long) {
        val current = read(KEY_FEED_NOTE)
        if (current == null || createdAt > current) store(KEY_FEED_NOTE, createdAt)
    }

    fun onBackground() {
        recordForeground()
        checkJob?.cancel()
        checkJob = scope.launch {
            while (isActive) {
                delay(CHECK_INTERVAL_MS)
                runCatching { checkOnce() }.onFailure { Log.w(TAG, "feed check failed: ${it.message}") }
            }
        }
    }

    fun onForeground() {
        checkJob?.cancel()
        checkJob = null
        recordForeground()
    }

    private suspend fun checkOnce() {
        val config = configStore.config.value
        if (!config.enablePushNotifications || !config.enableFeedNotifications) return
        val now = System.currentTimeMillis() / 1000
        if (!FeedNotesPolicy.shouldAnnounceAbsenceSummary(now, read(KEY_FOREGROUND), read(KEY_FEED_SUMMARY))) return
        val watermark = read(KEY_FEED_NOTE) ?: run {
            // No baseline yet: start counting from now.
            store(KEY_FEED_NOTE, now)
            return
        }
        val feed = feedService.get()
        val follows = feed.followedPubkeys.value
        if (follows.isEmpty()) return
        val showReplies = feed.showReplies.value
        val showReposts = feed.showReposts.value

        val kinds = if (showReposts) listOf(1, 6) else listOf(1)
        val filters = follows.chunked(AUTHORS_PER_FILTER).map { chunk ->
            buildJsonObject {
                put("kinds", buildJsonArray { kinds.forEach { add(JsonPrimitive(it)) } })
                put("authors", buildJsonArray { chunk.forEach { add(JsonPrimitive(it)) } })
                put("since", watermark + 1)
                put("limit", 500)
            }.toString()
        }
        val events = nostrService.get().queryRawEvents(filters, config.activeFeedRelays, timeoutMs = 20_000)
        val dates = events.mapNotNull { ev ->
            val kind = (ev["kind"] as? JsonPrimitive)?.longOrNull?.toInt() ?: return@mapNotNull null
            val createdAt = (ev["created_at"] as? JsonPrimitive)?.longOrNull ?: return@mapNotNull null
            val tags = (ev["tags"] as? JsonArray)?.mapNotNull { t ->
                (t as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
            }.orEmpty()
            createdAt.takeIf { FeedNotesPolicy.countsAsFeedNote(kind, tags, showReplies, showReposts) }
        }
        val newCount = FeedNotesPolicy.unannouncedFeedNoteCount(dates, watermark)
        if (newCount <= 0) return

        // Watermark forward only when the user is actually told.
        store(KEY_FEED_SUMMARY, now)
        dates.maxOrNull()?.let(::recordAnnouncedFeedNote)
        localNotificationService.get().postFeedSummary(newCount)
    }
}
