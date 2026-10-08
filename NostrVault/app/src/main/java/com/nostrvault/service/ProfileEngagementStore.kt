package com.nostrvault.service

import android.content.Context
import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.EngagementEvent
import com.nostrvault.data.model.EngagementLedger
import com.nostrvault.data.model.PostEngagement
import com.nostrvault.data.model.PostEngagementQuery
import com.nostrvault.relay.RelayForegroundService
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Likes, reposts, replies, quotes and zap sats for the posts on a profile:
 * best effort from relays, kept on the phone so they aren't pulled again.
 *
 * Each post's ledger (who liked, reposted, replied, quoted, zapped) is saved.
 * The first visit asks relays for everything; later visits ask only for what's
 * newer than the last check and add it, so numbers climb toward the real total
 * across visits without anything counted twice. One batched query per page of
 * posts, to the author's inbox relays (NIP-65) first, then their write relays
 * and the feed relays. Port of iOS ProfileEngagementStore.swift.
 */
@Singleton
class ProfileEngagementStore @Inject constructor(
    @ApplicationContext private val context: Context,
    private val nostrService: NostrService,
    private val configStore: ConfigStore,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val json = Json { ignoreUnknownKeys = true }
    private val lock = Any()

    private val _ledgers = MutableStateFlow<Map<String, EngagementLedger>>(emptyMap())
    val ledgers: StateFlow<Map<String, EngagementLedger>> = _ledgers.asStateFlow()

    private val inFlight = HashSet<String>()
    private val saveScheduled = AtomicBoolean(false)
    @Volatile private var loadedFromDisk = false

    fun engagement(ledgers: Map<String, EngagementLedger>, id: String): PostEngagement? =
        ledgers[id]?.engagement?.takeIf { !it.isEmpty }

    /**
     * Loads counts for [ids], posts by [author].
     * @param force ask again even for posts checked a moment ago
     *   (pull-to-refresh). Still only for what's new.
     */
    suspend fun load(ids: List<String>, author: String, force: Boolean = false) {
        // Called from a screen's scope: the first read of the file stays off the main thread.
        withContext(Dispatchers.IO) { ensureLoadedFromDisk() }
        val now = System.currentTimeMillis() / 1000
        val due = synchronized(lock) {
            val ledgers = _ledgers.value
            ids.distinct().filter { id ->
                id !in inFlight && (force || ledgers[id]?.checkedAt?.let { now - it > FRESH_FOR_SECS } ?: true)
            }.also { inFlight.addAll(it) }
        }
        if (due.isEmpty()) return
        try {
            val relays = relays(author)
            if (relays.isEmpty()) return
            // Your own posts, with your inbox relay asked, are counted from what
            // was sent to you; anything else may be missing likes on other relays.
            val lowerBound = relays.none { it.endsWith("/inbox") }

            val ledgers = _ledgers.value
            val (known, fresh) = due.partition { ledgers[it]?.checkedAt != null }
            var filters = PostEngagementQuery.filters(fresh)
            known.mapNotNull { ledgers[it]?.checkedAt }.minOrNull()?.let { oldest ->
                // Likes created shortly before the last check can still be on
                // their way to a relay; reach back this far. The ledger drops repeats.
                filters = filters + PostEngagementQuery.filters(known, since = oldest - SINCE_SLACK_SECS)
            }

            val targets = due.toSet()
            val events = nostrService.queryRawEvents(
                filters = filters,
                relayUrls = relays,
                timeoutMs = QUERY_TIMEOUT_MS,
                // Counts fill in as each relay answers rather than all at the end.
                onProgress = { partial ->
                    absorb(contributions(partial, targets), lowerBound, checkedAt = null)
                },
            )
            absorb(contributions(events, targets), lowerBound, checkedAt = now, checked = due)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "engagement load failed: ${e.message}")
        } finally {
            synchronized(lock) { inFlight.removeAll(due.toSet()) }
        }
    }

    private fun contributions(events: List<kotlinx.serialization.json.JsonObject>, targets: Set<String>) =
        PostEngagementQuery.contributions(events.mapNotNull(EngagementEvent::from), targets)

    /**
     * @param checked posts to stamp as asked about at [checkedAt], including
     *   ones nobody engaged with, so they aren't asked about again until they
     *   go stale.
     */
    private fun absorb(
        found: Map<String, EngagementLedger>,
        lowerBound: Boolean,
        checkedAt: Long?,
        checked: List<String> = emptyList(),
    ) {
        val changed = synchronized(lock) {
            val current = _ledgers.value
            val next = current.toMutableMap()
            for ((id, seen) in found) {
                var ledger = (next[id] ?: EngagementLedger()).absorbing(seen)
                if (!lowerBound) ledger = ledger.copy(isLowerBound = false)
                next[id] = ledger
            }
            if (checkedAt != null) {
                for (id in checked) {
                    var ledger = (next[id] ?: EngagementLedger()).copy(checkedAt = checkedAt)
                    if (!lowerBound) ledger = ledger.copy(isLowerBound = false)
                    next[id] = ledger
                }
            }
            if (next == current) false else { _ledgers.value = next; true }
        }
        if (changed) scheduleSave()
    }

    // ── Disk ─────────────────────────────────────────────────────────

    private fun file(): File = File(context.filesDir, FILENAME)

    private fun ensureLoadedFromDisk() {
        if (loadedFromDisk) return
        synchronized(lock) {
            if (loadedFromDisk) return
            loadedFromDisk = true
            val saved = try {
                file().takeIf { it.exists() }?.readText()
                    ?.let { json.decodeFromString<Map<String, EngagementLedger>>(it) }
            } catch (e: Exception) {
                Log.w(TAG, "engagement ledgers unreadable: ${e.message}")
                null
            }
            // Anything counted before the file was read wins over the file.
            if (saved != null) _ledgers.value = saved + _ledgers.value
        }
    }

    /** Writes at most every few seconds; a profile page fills in many rows at once. */
    private fun scheduleSave() {
        if (!saveScheduled.compareAndSet(false, true)) return
        scope.launch {
            delay(SAVE_DELAY_MS)
            saveScheduled.set(false)
            save()
        }
    }

    private fun save() {
        val kept = synchronized(lock) {
            var ledgers = _ledgers.value
            if (ledgers.size > MAX_LEDGERS) {
                ledgers = ledgers.entries
                    .sortedByDescending { it.value.checkedAt ?: 0L }
                    .take(MAX_LEDGERS)
                    .associate { it.key to it.value }
                _ledgers.value = ledgers
            }
            ledgers
        }
        try {
            val tmp = File(context.filesDir, "$FILENAME.tmp")
            tmp.writeText(json.encodeToString(kept))
            tmp.renameTo(file())
        } catch (e: Exception) {
            Log.w(TAG, "engagement ledgers not saved: ${e.message}")
        }
    }

    // ── Relays ───────────────────────────────────────────────────────

    /**
     * The author's inbox relays first (where reactions, replies and zap
     * receipts are sent), then their write relays, then the feed relays. For
     * your own profile, your own embedded inbox relay, which already holds
     * what was sent to you.
     */
    private fun relays(author: String): List<String> {
        val config = configStore.config.value
        if (nostrService.relayLists.value[author] == null) nostrService.fetchRelayList(author)

        val urls = buildList {
            // Only while it runs: a relay that is down answers nothing, and the
            // counts would still be marked exact.
            val base = config.nostrURL?.trimEnd('/')
            val relayUp = RelayForegroundService.relayStatus.value == RelayForegroundService.RelayStatus.RUNNING
            if (author == configStore.activeAccountHexPubkey.value && relayUp && !base.isNullOrEmpty()) add("$base/inbox")
            addAll(nostrService.relayLists.value[author].orEmpty().take(3))
            addAll(nostrService.outboxRelays.value[author].orEmpty().take(2))
            addAll(config.readRelays)
        }
        val seen = HashSet<String>()
        return urls.map { it.trim() }
            .filter { it.isNotEmpty() && seen.add(it.lowercase().trimEnd('/')) }
            .take(MAX_RELAYS)
    }

    private companion object {
        const val TAG = "ProfileEngagement"
        const val FILENAME = "engagement_ledgers.json"
        /** A post checked this recently isn't asked about again. */
        const val FRESH_FOR_SECS = 5 * 60L
        const val SINCE_SLACK_SECS = 15 * 60L
        const val MAX_LEDGERS = 3_000
        const val MAX_RELAYS = 6
        const val QUERY_TIMEOUT_MS = 6_000L
        const val SAVE_DELAY_MS = 3_000L
    }
}
