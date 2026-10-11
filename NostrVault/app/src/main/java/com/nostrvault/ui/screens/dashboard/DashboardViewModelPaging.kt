package com.nostrvault.ui.screens.dashboard

import android.util.Log
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import kotlinx.coroutines.launch
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.model.*
import com.nostrvault.service.NostrEvent
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*
import java.io.File
import com.nostrvault.ui.screens.dashboard.DashboardViewModel.Companion.TAG
import com.nostrvault.ui.screens.dashboard.DashboardViewModel.Companion.LOAD_MORE_TIMEOUT_MS
import com.nostrvault.ui.screens.dashboard.DashboardViewModel.Companion.SNAPSHOT_MAX_AGE_MS
import com.nostrvault.ui.screens.dashboard.DashboardViewModel.Companion.SNAPSHOT_FILE
import com.nostrvault.ui.screens.dashboard.DashboardViewModel.Companion.OLDER_PAGE_SIZE

    internal suspend fun DashboardViewModel.restoreSnapshotIfAvailable(): Boolean = withContext(Dispatchers.IO) {
        try {
            val dir = configStore.config.value.appSupportDir ?: return@withContext false
            val file = File(dir, SNAPSHOT_FILE)
            if (!file.exists()) return@withContext false

            val snapshot = json.decodeFromString<DiskVaultSnapshot>(file.readText())
            if (System.currentTimeMillis() - snapshot.savedAt > SNAPSHOT_MAX_AGE_MS) {
                file.delete()
                return@withContext false
            }

            allEventsMutex.withLock {
                for (event in snapshot.events) {
                    allEvents.add(event)
                    seenIds.add(event.id)
                }
                newestEventCreatedAt = allEvents.maxOfOrNull { it.createdAt } ?: 0L
            }
            true
        } catch (e: Exception) {
            Log.w(TAG, "Vault snapshot restore failed: ${e.message}")
            false
        }
    }

    internal fun DashboardViewModel.buildAuthorSet(): Set<String> {
        val config = configStore.config.value
        val authors = mutableSetOf<String>()
        val ownerHex = nostrService.activeHexPubkey
        if (ownerHex.isNotEmpty()) authors.add(ownerHex)
        config.whitelistedNpubs?.forEach { npub ->
            nostrService.npubToHex(npub)?.let { authors.add(it) }
        }
        return authors
    }

    fun DashboardViewModel.loadMore() {
        Log.d(TAG, "loadMore called: isLoadingMore=${_isLoadingMore.value}, viewMode=${_viewMode.value}, notesCount=${_displayNotes.value.size}")
        if (_isLoadingMore.value) return
        // Articles and Highlights page by their own button (loadOlderInScope).
        if (_viewMode.value == VaultViewMode.NOTES && _noteScope.value.pagesByButton) return
        val currentNotes = _displayNotes.value
        if (currentNotes.isEmpty()) return

        // For notes mode, show more of what is loaded, and pull older notes
        // from the relay once everything loaded is listed. Without raising the
        // cap the list stopped at 50: older notes loaded underneath but never
        // showed (iOS #273).
        if (_viewMode.value == VaultViewMode.NOTES) {
            val hiddenBelowCap = relayNotesHiddenBelowCap(notesFilteredCount, maxDisplayedItems)
            maxDisplayedItems += 50
            if (hiddenBelowCap) {
                scheduleUpdateDisplayData()
                return
            }
            val oldest = currentNotes.lastOrNull()?.createdAt ?: return
            val config = configStore.config.value
            if (config.nostrURL == null) {
                Log.w(TAG, "loadMore: No relay URL configured")
                return
            }
            val localUrl = config.nostrURL ?: return
            val inboxUrl = config.localInboxURL ?: return

            // Build author set matching loadLocalRelayNotes
            val ownerHex = nostrService.activeHexPubkey
            val authors = mutableSetOf<String>()
            if (ownerHex.isNotEmpty()) authors.add(ownerHex)
            config.whitelistedNpubs?.forEach { npub ->
                nostrService.npubToHex(npub)?.let { authors.add(it) }
            }

            _isLoadingMore.value = true

            viewModelScope.launch(Dispatchers.IO) {
                val untilSecs = oldest.time / 1000 - 1
                val authorsJson = authors.joinToString(",") { "\"$it\"" }
                val authorFilter = """{"kinds":[1,6,7,30023,1111,9802,9735,1068],"authors":[$authorsJson],"until":$untilSecs,"limit":200}"""

                val filters = if (ownerHex.isNotEmpty()) {
                    val mentionsFilter = """{"kinds":[1,6,7,30023,1111,9802,9735,1068],"#p":["$ownerHex"],"until":$untilSecs,"limit":300}"""
                    "$authorFilter,$mentionsFilter"
                } else {
                    authorFilter
                }

                // Query outbox
                val (outboxRaw, _) = queryRelayEndpoint(localUrl, filters, "outbox-hist", LOAD_MORE_TIMEOUT_MS)

                // Query inbox for older tagged notes
                val (inboxRaw, _) = queryRelayEndpoint(inboxUrl, filters, "inbox-hist", LOAD_MORE_TIMEOUT_MS)

                allEventsMutex.withLock {
                    allEvents.addAll(outboxRaw)
                    allEvents.addAll(inboxRaw)
                    trimAllEventsLocked()
                }

                withContext(Dispatchers.Main.immediate) {
                    _isLoadingMore.value = false
                }

                scheduleUpdateDisplayData()
            }
        } else {
            // For likes/zaps mode, just increase the display limit
            maxDisplayedItems += 50
            scheduleUpdateDisplayData()
        }
    }

    // ── Mode & filter setters ────────────────────────────────────

    /**
     * Articles and Highlights open on their newest page. The relay's first
     * load is the newest posts of every kind together, so an article older
     * than those was in none of it, and the list said "No articles found"
     * until you tapped Load older. Runs once that first load is in.
     */
    internal fun DashboardViewModel.loadFirstPageInScope() {
        val scope = _noteScope.value
        if (!scope.pagesByButton || scope in _noOlderPages.value) return
        val kind = scope.kinds(RELAY_TAB_NOTE_KINDS).single()
        viewModelScope.launch {
            val loaded = allEventsMutex.withLock { allEvents.any { it.kind == kind } }
            if (!loaded) loadOlderInScope()
        }
    }

    /**
     * Articles' and Highlights' "Load older": one page of just that kind from
     * the local relay, older than the oldest one loaded, however far back.
     * It leaves Notes' paging alone, so Notes can't skip what lies between.
     * These lists have no display cap (see updateDisplayData), so every row
     * loaded is already listed.
     */
    fun DashboardViewModel.loadOlderInScope() {
        val scope = _noteScope.value
        if (_viewMode.value != VaultViewMode.NOTES || !scope.pagesByButton || _isLoadingOlder.value) return
        val config = configStore.config.value
        val outboxUrl = config.nostrURL ?: return
        val inboxUrl = config.localInboxURL
        val ownerHex = nostrService.activeHexPubkey
        val authors = buildList {
            if (ownerHex.isNotEmpty()) add(ownerHex)
            config.whitelistedNpubs?.forEach { npub -> nostrService.npubToHex(npub)?.let(::add) }
        }.distinct()
        if (authors.isEmpty()) return
        val kind = scope.kinds(RELAY_TAB_NOTE_KINDS).single()
        val gen = olderGeneration
        _isLoadingOlder.value = true
        viewModelScope.launch(Dispatchers.IO) {
            val authorSet = authors.toSet()
            fun mine(e: NostrEvent) = e.kind == kind && e.pubkey in authorSet
            fun tagged(e: NostrEvent) = e.kind == kind && e.tags.any { it.size >= 2 && it[0] == "p" && it[1] == ownerHex }
            val loaded = allEventsMutex.withLock { allEvents.filter { it.kind == kind } }
            val now = System.currentTimeMillis() / 1000
            val (outCursor, inCursor) = olderCursors[scope] ?: Pair(
                VaultPageCursor.start(loaded.filter(::mine).map { it.createdAt }, now),
                // No inbox or no account to be tagged: nothing to page there.
                VaultPageCursor.start(loaded.filter(::tagged).map { it.createdAt }, now)
                    .let { if (inboxUrl == null || ownerHex.isEmpty()) it.copy(done = true) else it },
            )

            suspend fun page(cursor: VaultPageCursor, url: String?, filter: String, label: String, keep: (NostrEvent) -> Boolean): Pair<VaultPageCursor, List<NostrEvent>> {
                if (cursor.done || url == null) return cursor to emptyList()
                val answered = java.util.concurrent.atomic.AtomicBoolean(false)
                val (raw, _) = queryRelayEndpoint(url, filter, label, LOAD_MORE_TIMEOUT_MS, dedupe = false, answered = answered)
                // A relay that never answered says nothing about what's older.
                if (!answered.get()) return cursor to emptyList()
                val page = raw.filter(keep)
                return cursor.after(page.map { it.createdAt }) to page
            }

            val authorsJson = authors.joinToString(",") { "\"$it\"" }
            val (nextOut, outEvents) = page(
                outCursor, outboxUrl,
                """{"kinds":[$kind],"authors":[$authorsJson],"until":${outCursor.until},"limit":$OLDER_PAGE_SIZE}""",
                "older-out", ::mine,
            )
            val (nextIn, inEvents) = page(
                inCursor, inboxUrl,
                """{"kinds":[$kind],"#p":["$ownerHex"],"until":${inCursor.until},"limit":$OLDER_PAGE_SIZE}""",
                "older-in", ::tagged,
            )

            if (gen != olderGeneration) return@launch
            val added = (outEvents + inEvents).filter { seenIds.add(it.id) }
            allEventsMutex.withLock {
                allEvents.addAll(added)
                trimAllEventsLocked()
            }
            olderCursors[scope] = nextOut to nextIn
            withContext(Dispatchers.Main.immediate) {
                if (nextOut.done && nextIn.done) _noOlderPages.value = _noOlderPages.value + scope
                _isLoadingOlder.value = false
            }
            scheduleUpdateDisplayData()
        }
    }
