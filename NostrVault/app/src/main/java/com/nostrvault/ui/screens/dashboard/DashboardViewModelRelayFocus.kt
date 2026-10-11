package com.nostrvault.ui.screens.dashboard

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import kotlinx.coroutines.launch
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.model.*
import com.nostrvault.service.NostrEvent
import com.nostrvault.ui.navigation.NotificationTarget
import com.nostrvault.ui.navigation.RelayFocusRequest
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*
import com.nostrvault.ui.screens.dashboard.DashboardViewModel.Companion.LOAD_MORE_TIMEOUT_MS

    /**
     * Switch to the list that holds a notification's event: likes → Likes on
     * my notes, zaps → Zaps on my notes, everything else → Notes / All. Filters
     * are only touched when they differ, since setting one resets its list.
     */
    suspend fun DashboardViewModel.applyRelayFocusView(request: RelayFocusRequest, zapsOnly: Boolean) {
        when (NotificationTarget.viewFor(request.type, zapsOnly)) {
            VaultViewMode.LIKES -> {
                if (_likesFilter.value != VaultLikesFilter.ON_MY_NOTES) setLikesFilter(VaultLikesFilter.ON_MY_NOTES)
                if (_viewMode.value != VaultViewMode.LIKES) setViewMode(VaultViewMode.LIKES)
            }
            VaultViewMode.ZAPS -> {
                if (_zapsFilter.value != VaultZapsFilter.ON_MY_NOTES) setZapsFilter(VaultZapsFilter.ON_MY_NOTES)
                if (_viewMode.value != VaultViewMode.ZAPS) setViewMode(VaultViewMode.ZAPS)
            }
            VaultViewMode.NOTES -> {
                // Notes leaves out articles and highlights: land on the list
                // that holds the target (again once it loads; alignFocusScope).
                setNoteScope(VaultNoteScope.forKind(focusEvent(request.eventId)?.kind))
                // A reply from outside your network isn't listed under All.
                val author = focusEvent(request.eventId)?.pubkey
                val target = if (author != null && VaultContentFilter.isOutside(
                        author, nostrService.activeHexPubkey, resolveWhitelistedHexPubkeys(),
                        feedService.relayTabTrustedPubkeys(),
                    )
                ) VaultContentFilter.OUTSIDE else VaultContentFilter.ALL
                if (_contentFilter.value != target) setContentFilter(target)
                if (_viewMode.value != VaultViewMode.NOTES) setViewMode(VaultViewMode.NOTES)
            }
            VaultViewMode.FOLLOWERS -> {
                if (_viewMode.value != VaultViewMode.FOLLOWERS) setViewMode(VaultViewMode.FOLLOWERS)
                return // a list, not an event: nothing to fetch
            }
        }
        fetchFocusEventIfMissing(request.eventId)
    }

    /**
     * A notification's event can load after the tap picked Notes for it; once
     * it has, move to the scope that lists it (an article or a highlight).
     */
    /** @return true once the event's kind is known: aligned, nothing more to do. */
    suspend fun DashboardViewModel.alignFocusScope(request: RelayFocusRequest, zapsOnly: Boolean): Boolean {
        val kind = focusEvent(request.eventId)?.kind ?: return false
        val scope = NotificationTarget.vaultModeFor(request.type, kind, zapsOnly).noteScope ?: return true
        if (_viewMode.value == VaultViewMode.NOTES && _noteScope.value != scope) setNoteScope(scope)
        return true
    }

    /**
     * The notification's event carries the target in its tags, so it has to be
     * at hand. It normally arrives over the live inbox subscription; on a cold
     * start that can lag, so also ask the local relays for it by id.
     */
    private fun DashboardViewModel.fetchFocusEventIfMissing(id: String) {
        viewModelScope.launch(Dispatchers.IO) {
            if (focusEvent(id) != null) return@launch
            val config = configStore.config.value
            val urls = listOfNotNull(config.nostrURL, config.localInboxURL).distinct()
            for (url in urls) {
                val (raw, _) = queryRelayEndpoint(
                    url, "{\"ids\":[\"$id\"]}", "focus", LOAD_MORE_TIMEOUT_MS, dedupe = false,
                )
                raw.firstOrNull { it.id == id }?.let {
                    focusEvents[id] = it
                    return@launch
                }
            }
        }
    }

    internal suspend fun DashboardViewModel.focusEvent(id: String): NostrEvent? =
        focusEvents[id] ?: allEventsMutex.withLock { allEvents.firstOrNull { it.id == id } }

    /**
     * The post to open when the event never shows up in the list (older than
     * the loaded page). Null when the notification's event could not be found,
     * since opening a reaction or zap receipt as a note shows nothing.
     */
    suspend fun DashboardViewModel.focusFallbackNoteId(request: RelayFocusRequest): String? =
        // A mention or reply is a note itself, so its id opens even untagged.
        NotificationTarget.targetNoteId(
            request.type, request.eventId, focusEvent(request.eventId)?.tags.orEmpty(),
        )

    // ── Display data processing (port of iOS VaultDataProcessing) ──
