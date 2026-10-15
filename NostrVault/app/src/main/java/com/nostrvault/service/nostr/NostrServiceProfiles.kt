package com.nostrvault.service

import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.ProfileUpdateSignal
import com.nostrvault.data.remote.WebSocketClient
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*
import kotlin.concurrent.withLock
import com.nostrvault.service.NostrService.Companion.MAX_CACHED_PROFILES
import com.nostrvault.service.NostrService.Companion.MAX_FETCH_ATTEMPTS
import com.nostrvault.service.NostrService.Companion.METADATA_IDLE_TIMEOUT_MS
import com.nostrvault.service.NostrService.Companion.METADATA_MAX_AUTHORS
import com.nostrvault.service.NostrService.Companion.METADATA_PENDING_WINDOW_MS
import com.nostrvault.service.NostrService.Companion.METADATA_POOL_SIZE
import com.nostrvault.service.NostrService.Companion.METADATA_SUB_ID
import com.nostrvault.service.NostrService.Companion.PROFILE_EMIT_DEBOUNCE_MS
import com.nostrvault.service.NostrService.Companion.PROFILE_FLUSH_DELAY_MS
import com.nostrvault.service.NostrService.Companion.PROFILE_RELAYS
import com.nostrvault.service.NostrService.Companion.PROFILE_RETRY_TTL_MS
import com.nostrvault.service.NostrService.Companion.PROFILE_SAVE_THROTTLE_MS
import com.nostrvault.service.NostrService.Companion.PROFILE_TTL_MS
import com.nostrvault.service.NostrService.Companion.PROFILE_UPDATE_DEBOUNCE_MS
import com.nostrvault.service.NostrService.Companion.TRIM_CACHED_PROFILES

    internal fun NostrService.loadProfilesFromDisk() {
        profileDiskLoad = scope.launch(Dispatchers.IO) {
            val loaded = profileRepository.loadProfiles()
            val relays = profileRepository.loadRelayLists()
            val outbox = profileRepository.loadOutboxRelays()
            val dmRelays = profileRepository.loadDMRelayLists()
            val servers = profileRepository.loadServerLists()
            // Merge, never replace: the metadata pool starts fetching before a
            // large cache file is parsed, and assigning the file's map threw away
            // every profile that had arrived meanwhile. Those pubkeys were
            // already marked as fetched, so they stayed an npub with a letter
            // avatar for PROFILE_RETRY_TTL_MS after every cold start.
            _profiles.update { live -> trimProfiles(mergeDiskProfiles(loaded, live)) }
            withContext(Dispatchers.Main.immediate) {
                _relayLists.value = relays + _relayLists.value
                _outboxRelays.value = outbox + _outboxRelays.value
                _dmRelayLists.value = dmRelays + _dmRelayLists.value
                _serverLists.value = servers + _serverLists.value
            }
        }
    }

    /**
     * [disk] overlaid with [live], the profiles fetched since launch. A live
     * entry wins unless the disk copy comes from a newer kind 0: before the
     * cache is read, nothing stops an older event from being accepted.
     */
    internal fun mergeDiskProfiles(
        disk: Map<String, FeedProfile>,
        live: Map<String, FeedProfile>,
    ): Map<String, FeedProfile> {
        if (live.isEmpty()) return disk
        val merged = HashMap(disk)
        for ((pubkey, profile) in live) {
            val saved = merged[pubkey]
            if (saved == null || (profile.createdAt ?: 0L) >= (saved.createdAt ?: 0L)) merged[pubkey] = profile
        }
        return merged
    }

    /**
     * Decide whether a pubkey's metadata is worth (re-)fetching. Must be called while
     * holding [profileQueueLock] (it reads [profileFetchAttempts]).
     *
     * Skips when: a fresh cached profile exists (within [PROFILE_TTL_MS]); a legacy cached
     * profile with no timestamp exists (preserves prior behaviour, avoids a first-launch
     * refetch storm); or a metadata REQ was dispatched recently (within
     * [PROFILE_RETRY_TTL_MS]) — the latter negatively-caches unresolvable pubkeys and
     * dedupes in-flight fetches. [force] bypasses freshness/retry but still skips nothing.
     */
    internal fun NostrService.shouldFetchProfile(
        pubkey: String,
        cached: FeedProfile?,
        now: Long,
        force: Boolean,
    ): Boolean {
        if (force) return true
        if (cached != null) {
            // Legacy entries (fetchedAt == null) are treated as fresh; stamped entries
            // refresh once their TTL lapses.
            val fresh = cached.fetchedAt?.let { now - it < PROFILE_TTL_MS } ?: true
            if (fresh) return false
        }
        val lastAttempt = profileFetchAttempts[pubkey]
        if (lastAttempt != null && now - lastAttempt < PROFILE_RETRY_TTL_MS) return false
        return true
    }

    internal fun NostrService.scheduleProfileFlush() {
        if (profileFlushJob != null) return
        profileFlushJob = scope.launch {
            delay(PROFILE_FLUSH_DELAY_MS)
            flushMetadataRequests()
        }
    }

    private fun NostrService.flushMetadataRequests() {
        val pubkeys = profileQueueLock.withLock {
            val batch = profileFetchQueue.toList()
            profileFetchQueue.clear()
            profileFlushJob = null
            batch
        }
        if (pubkeys.isEmpty()) return

        val readRelays = configStore.config.value.readRelays

        // Record the dispatch time so these pubkeys are negatively-cached for
        // PROFILE_RETRY_TTL_MS even if no kind-0 comes back (no resolvable profile, or it
        // arrives after the temp-client timeout). Prevents re-fetch churn on every note.
        val now = System.currentTimeMillis()
        profileQueueLock.withLock {
            pubkeys.forEach { profileFetchAttempts[it] = now }
            if (profileFetchAttempts.size > MAX_FETCH_ATTEMPTS) {
                profileFetchAttempts.entries
                    .removeAll { now - it.value >= PROFILE_RETRY_TTL_MS }
            }
        }

        // The pool shares one sub id, so each REQ *replaces* the last on every
        // relay, and a REQ sent before a socket connects is dropped (send()
        // returns false; only the latest filter is re-sent on connect). A filter
        // of just this flush's pubkeys therefore cancelled every earlier batch
        // still in flight, and those pubkeys were then negatively cached for
        // PROFILE_RETRY_TTL_MS: on a cold start almost every feed author stayed
        // an npub with a letter avatar. Ask for everything still unanswered.
        val filterJson = pendingMetadataFilterJson(now) ?: return
        lastMetadataFilterJson = filterJson

        // Reuse a small pool of WARM connections to the Blastr relays (kind 0 is
        // widely replicated) instead of opening fresh sockets per flush. A stable
        // sub id means each flush just replaces the filter on the open sockets.
        // The user's own relay (first in readRelays when configured) leads,
        // then the profile relays, then the rest of Blastr.
        val relays = (readRelays.take(1) + PROFILE_RELAYS + readRelays)
            .distinct()
            .filter { isValidRelayUrl(it) }
            .take(METADATA_POOL_SIZE)
        if (relays.isEmpty()) return
        metadataPoolLock.withLock {
            // Drop pooled relays no longer in the configured set.
            val keep = relays.toSet()
            metadataClients.keys.filter { it !in keep }.toList().forEach { url ->
                metadataClients.remove(url)?.disconnect()
            }
            for (relayUrl in relays) {
                val client = metadataClients.getOrPut(relayUrl) { createMetadataClient(relayUrl) }
                // CLOSE first: a relay may refuse a REQ that reuses the id of a
                // subscription it still holds open, rather than replace it.
                client.send("[\"CLOSE\",\"$METADATA_SUB_ID\"]")
                client.send("[\"REQ\",\"$METADATA_SUB_ID\",$filterJson]")
            }
        }
        armMetadataIdleTimeout()
    }

    /**
     * kind-0 filter for every pubkey dispatched in the last
     * [METADATA_PENDING_WINDOW_MS] whose metadata has not arrived since, newest
     * first, capped at [METADATA_MAX_AUTHORS]. Null when nothing is pending.
     */
    private fun NostrService.pendingMetadataFilterJson(now: Long): String? {
        val profiles = _profiles.value
        val staged = profileEmitLock.withLock { pendingProfiles.keys.toSet() }
        val authors = profileQueueLock.withLock {
            profileFetchAttempts.entries
                .filter { (pubkey, attemptedAt) ->
                    now - attemptedAt < METADATA_PENDING_WINDOW_MS &&
                        pubkey !in staged &&
                        (profiles[pubkey]?.fetchedAt ?: 0L) < attemptedAt
                }
                .sortedByDescending { it.value }
                .take(METADATA_MAX_AUTHORS)
                .map { it.key }
        }
        if (authors.isEmpty()) return null
        return buildFilterJson(buildMap<String, Any> {
            put("kinds", listOf(0))
            put("authors", authors)
        })
    }

    /** Open a long-lived metadata-pool connection that survives across flushes. */
    private fun NostrService.createMetadataClient(relayUrl: String): WebSocketClient {
        val client = WebSocketClient(url = relayUrl, scope = scope)
        scope.launch(Dispatchers.Default) {
            client.messages.collect { msg ->
                launch(Dispatchers.Default) { processRelayMessage(msg, relayUrl) }
            }
        }
        // Re-issue the latest filter on every (re)connect so a dropped subscription
        // recovers without waiting for the next flush.
        scope.launch {
            client.connectionState.collect { state ->
                if (state == WebSocketClient.ConnectionState.CONNECTED) {
                    val filterJson = pendingMetadataFilterJson(System.currentTimeMillis())
                        ?: lastMetadataFilterJson.takeIf { it.isNotEmpty() }
                    if (filterJson != null) {
                        client.send("[\"REQ\",\"$METADATA_SUB_ID\",$filterJson]")
                    }
                }
            }
        }
        client.connect()
        return client
    }

    /** Close the metadata pool after a quiet period to free idle connections. */
    private fun NostrService.armMetadataIdleTimeout() {
        metadataIdleJob?.cancel()
        metadataIdleJob = scope.launch {
            delay(METADATA_IDLE_TIMEOUT_MS)
            closeMetadataPool()
        }
    }

    internal fun NostrService.closeMetadataPool() {
        metadataIdleJob?.cancel()
        metadataPoolLock.withLock {
            metadataClients.values.forEach { it.disconnect() }
            metadataClients.clear()
        }
    }

    internal fun NostrService.parseAndCacheProfile(pubkey: String, content: String, createdAt: Long) {
        val existingProfile = _profiles.value[pubkey]
        val result = profileRepository.parseMetadataContent(content, pubkey, existingProfile) ?: return
        val (parsed, changed) = result
        val now = System.currentTimeMillis()

        if (!changed && existingProfile != null) {
            // Content identical to cache — just reset the freshness TTL. Skip the duplicate
            // relay responses that arrive in the same fetch burst (entry already stamped)
            // to avoid redundant StateFlow emissions.
            val lastStamp = existingProfile.fetchedAt
            if (lastStamp != null && now - lastStamp < PROFILE_RETRY_TTL_MS) return
            // Freshness-only refresh: stage it, but no UI-change signal needed.
            stageProfile(pubkey, existingProfile.copy(fetchedAt = now, createdAt = createdAt), notify = false)
            return
        }

        stageProfile(pubkey, parsed.copy(fetchedAt = now, createdAt = createdAt), notify = true)
    }

    /** Stage a parsed profile for the next batched emission window (see [pendingProfiles]). */
    private fun NostrService.stageProfile(pubkey: String, profile: FeedProfile, notify: Boolean) {
        profileEmitLock.withLock {
            pendingProfiles[pubkey] = profile
            if (notify) pendingProfileNotify.add(pubkey)
            if (profileEmitJob?.isActive == true) return
            profileEmitJob = scope.launch(Dispatchers.Default) {
                delay(PROFILE_EMIT_DEBOUNCE_MS)
                flushProfileEmissions()
            }
        }
    }

    /** Merge all staged profiles into [_profiles] in ONE rebuild + ONE emission, off-main. */
    private fun NostrService.flushProfileEmissions() {
        val snapshot: Map<String, FeedProfile>
        val notify: Set<String>
        profileEmitLock.withLock {
            profileEmitJob = null
            if (pendingProfiles.isEmpty()) return
            snapshot = HashMap(pendingProfiles)
            pendingProfiles.clear()
            notify = HashSet(pendingProfileNotify)
            pendingProfileNotify.clear()
        }
        // MutableStateFlow.value writes are thread-safe → do the heavy merge/trim
        // here on Default (this runs from a Dispatchers.Default coroutine).
        // update, not read-then-write: loadProfilesFromDisk merges concurrently.
        _profiles.update { trimProfiles(it + snapshot) }
        notify.forEach { noteProfileUpdated(it) }
        if (notify.isNotEmpty()) saveProfilesThrottled()
    }

    /**
     * Keep the in-memory profile map bounded. When it exceeds [MAX_CACHED_PROFILES],
     * retain the [TRIM_CACHED_PROFILES] freshest entries (by fetchedAt) plus the owner's
     * own profile. Disk converges to the trimmed set on the next throttled save.
     */
    private fun NostrService.trimProfiles(profiles: Map<String, FeedProfile>): Map<String, FeedProfile> {
        if (profiles.size <= MAX_CACHED_PROFILES) return profiles
        val kept = profiles.entries
            .sortedByDescending { it.value.fetchedAt ?: 0L }
            .take(TRIM_CACHED_PROFILES)
            .associate { it.key to it.value }
        val owner = ownerHexPubkey
        return if (owner.isNotEmpty() && !kept.containsKey(owner) && profiles.containsKey(owner)) {
            kept + (owner to profiles.getValue(owner))
        } else {
            kept
        }
    }

    /**
     * Signal that a profile has been updated (coalesced, debounced).
     */
    fun NostrService.noteProfileUpdated(pubkey: String) {
        profileUpdateLock.withLock {
            pendingProfileUpdates.add(pubkey)
        }

        profileUpdateJob?.cancel()
        profileUpdateJob = scope.launch {
            delay(PROFILE_UPDATE_DEBOUNCE_MS)
            val pubkeys = profileUpdateLock.withLock {
                val set = pendingProfileUpdates.toSet()
                pendingProfileUpdates.clear()
                set
            }
            if (pubkeys.isNotEmpty()) {
                profileUpdateGeneration++
                _profileUpdates.emit(
                    ProfileUpdateSignal(profileUpdateGeneration, pubkeys)
                )
            }
        }
    }

    /**
     * Write the profile cache at most once per [PROFILE_SAVE_THROTTLE_MS], and
     * always once more after the last change. Returning early inside the window
     * dropped that trailing save: everything fetched in the last few seconds of
     * a session never reached disk, so the same profiles were missing again
     * after every relaunch.
     */
    fun NostrService.saveProfilesThrottled() {
        val now = System.currentTimeMillis()
        // A queued save that hasn't read the maps yet will include this change.
        if (profileSaveJob?.isActive == true && now < lastProfileSaveTime) return
        val saveAt = nextProfileSaveAt(now, lastProfileSaveTime)
        lastProfileSaveTime = saveAt

        profileSaveJob = scope.launch(Dispatchers.IO) {
            delay(saveAt - now)
            // Writing before the cache is read would replace the file with only
            // what arrived since launch.
            profileDiskLoad?.join()
            profileRepository.saveProfiles(_profiles.value)
            profileRepository.saveRelayLists(_relayLists.value)
            profileRepository.saveOutboxRelays(_outboxRelays.value)
            profileRepository.saveDMRelayLists(_dmRelayLists.value)
            profileRepository.saveServerLists(_serverLists.value)
        }
    }

    /** When the next throttled save may run: now, or one window after the last. */
    internal fun nextProfileSaveAt(now: Long, lastSaveAt: Long): Long =
        maxOf(now, lastSaveAt + PROFILE_SAVE_THROTTLE_MS)

    internal fun NostrService.prefetchWhitelistedProfiles() {
        // Cover the whole roster: multi-account (owner + accountNpubs) plus any
        // relay-follow whitelisted accounts, so every switchable account's
        // kind-0 (name/avatar) is fetched.
        val cfg = configStore.config.value
        val npubs = (cfg.allAccountNpubs() + (cfg.whitelistedNpubs ?: emptyList())).distinct()
        val hexes = npubs.mapNotNull { npubToHex(it) }
        if (hexes.isNotEmpty()) fetchMissingProfiles(hexes)
    }

    /**
     * Queue pubkeys for batched profile metadata fetch.
     */
    internal fun NostrService.fetchMissingProfilesImpl(pubkeys: List<String>, force: Boolean = false) {
        val now = System.currentTimeMillis()
        val currentProfiles = _profiles.value
        val missing = profileQueueLock.withLock {
            pubkeys.filter { pk -> shouldFetchProfile(pk, currentProfiles[pk], now, force) }
                .also { profileFetchQueue.addAll(it) }
        }
        if (missing.isEmpty()) return

        scheduleProfileFlush()
    }

    /**
     * Shows [profile] for [pubkey] at once, ahead of the relays: your own
     * edit while it publishes, or what was shown before when that failed.
     * Null removes the entry.
     */
    internal fun NostrService.showLocalProfileImpl(pubkey: String, profile: FeedProfile?) {
        _profiles.update { if (profile == null) it - pubkey else it + (pubkey to profile) }
        noteProfileUpdated(pubkey)
        saveProfilesThrottled()
    }
