package com.nostrvault.service

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import java.util.UUID
import com.nostrvault.service.NostrService.Companion.PROFILE_RELAYS
import com.nostrvault.service.NostrService.Companion.RELAY_LIST_CHUNK
import com.nostrvault.service.NostrService.Companion.RELAY_LIST_TIMEOUT_MS
import com.nostrvault.service.NostrService.Companion.TEMP_CLIENT_DISCONNECT_MS

    internal fun NostrService.parseRelayListEvent(pubkey: String, tags: List<List<String>>, createdAt: Long) {
        val (readRelays, writeRelays) = profileRepository.parseRelayListTags(tags)
        scope.launch(Dispatchers.Main.immediate) {
            val known = relayListCreatedAt[pubkey]
            if (known != null && createdAt < known) return@launch
            relayListCreatedAt[pubkey] = createdAt
            if (readRelays.isNotEmpty()) {
                _relayLists.value = _relayLists.value + (pubkey to readRelays)
            }
            if (writeRelays.isNotEmpty()) {
                _outboxRelays.value = _outboxRelays.value + (pubkey to writeRelays)
            }
        }
    }

    internal fun NostrService.parseDmRelayListEvent(pubkey: String, tags: List<List<String>>) {
        val dmRelays = profileRepository.parseDMRelayListTags(tags)
        if (dmRelays.isNotEmpty()) {
            scope.launch(Dispatchers.Main.immediate) {
                _dmRelayLists.value = _dmRelayLists.value + (pubkey to dmRelays)
            }
        }
    }

    internal fun NostrService.parseServerListEvent(pubkey: String, tags: List<List<String>>) {
        val servers = profileRepository.parseServerListTags(tags)
        if (servers.isNotEmpty()) {
            scope.launch(Dispatchers.Main.immediate) {
                _serverLists.value = _serverLists.value + (pubkey to servers)
            }
        }
    }

    internal fun NostrService.parseMuteListEvent(tags: List<List<String>>) {
        val mutedNpubs = profileRepository.parseMuteListPTags(tags).mapNotNull { hexToNpub(it) }
        // The owner's kind-10000 mute list. Sync into the owner's per-account blocked
        // list (and the legacy flat field for backward compatibility).
        configStore.update { config ->
            val ownerKey = config.ownerNpub
            config.copy(
                blockedNpubs = mutedNpubs,
                blockedNpubsPerAccount = if (ownerKey.isNotEmpty())
                    config.blockedNpubsPerAccount + (ownerKey to mutedNpubs)
                else config.blockedNpubsPerAccount,
            )
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // Relay list fetching
    // ══════════════════════════════════════════════════════════════════

    /**
     * Fetch relay list (kinds 10002, 10050) for a specific pubkey.
     */
    fun NostrService.fetchRelayList(pubkey: String) {
        if (_relayLists.value.containsKey(pubkey) && _dmRelayLists.value.containsKey(pubkey)) {
            return
        }

        val subId = "relays-${UUID.randomUUID().toString().take(8)}"
        val filter = buildMap<String, Any> {
            put("kinds", listOf(10002, 10050))
            put("authors", listOf(pubkey))
            put("limit", 2)
        }

        val readRelays = configStore.config.value.readRelays
        for (relayUrl in readRelays.take(3)) {
            if (!isValidRelayUrl(relayUrl)) continue
            scope.launch(Dispatchers.IO) {
                lookupPool.query(relayUrl, subId, listOf(buildFilterJson(filter)), TEMP_CLIENT_DISCONNECT_MS) { msg ->
                    launch(Dispatchers.Default) { processRelayMessage(msg, relayUrl) }
                }
            }
        }
    }

    /**
     * Fetch NIP-65 relay lists (kind 10002) for many pubkeys at once, on the
     * pooled lookup sockets. The metadata pool asks for kind 0 only, so a
     * forced [fetchMissingProfiles] never brings these in. Asks the user's own
     * relay and the profile relays (purplepag.es and user.kindpag.es index
     * relay lists).
     */
    fun NostrService.fetchRelayLists(pubkeys: List<String>) {
        if (pubkeys.isEmpty()) return
        val relays = (configStore.config.value.readRelays.take(1) + PROFILE_RELAYS)
            .distinct()
            .filter { isValidRelayUrl(it) }
        for (chunk in pubkeys.distinct().chunked(RELAY_LIST_CHUNK)) {
            val filter = buildFilterJson(buildMap<String, Any> {
                put("kinds", listOf(10002))
                put("authors", chunk)
                put("limit", chunk.size)
            })
            for (relayUrl in relays) {
                val subId = "relays-${UUID.randomUUID().toString().take(8)}"
                scope.launch(Dispatchers.IO) {
                    lookupPool.query(relayUrl, subId, listOf(filter), RELAY_LIST_TIMEOUT_MS) { msg ->
                        launch(Dispatchers.Default) { processRelayMessage(msg, relayUrl) }
                    }
                }
            }
        }
    }

    /**
     * The newest signed kind 10050 for [pubkey] across the blastr relays and
     * [alsoAsk], as (relays, created_at), or null if none answered in time.
     * Asks fresh rather than trusting the cached [dmRelayLists], which would
     * let a device adopt its own stale copy.
     */
    internal suspend fun NostrService.fetchNewestDMRelayList(pubkey: String, alsoAsk: List<String>, timeoutMs: Long = 6_000): Pair<List<String>, Long>? {
        val winner = fetchNewestReplaceable(10050, pubkey, alsoAsk, timeoutMs) ?: return null
        return profileRepository.parseDMRelayListTags(winner.tags) to winner.createdAt
    }
