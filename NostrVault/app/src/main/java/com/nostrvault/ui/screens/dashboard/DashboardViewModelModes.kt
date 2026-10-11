package com.nostrvault.ui.screens.dashboard

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import kotlinx.coroutines.launch
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.model.*
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*
import com.nostrvault.ui.screens.dashboard.DashboardViewModel.Companion.SAVED_VIEW_MODE
import com.nostrvault.ui.screens.dashboard.DashboardViewModel.Companion.SAVED_NOTE_SCOPE
import com.nostrvault.ui.screens.dashboard.DashboardViewModel.Companion.SAVED_RECIPES

    /** The newest created_at in each dotted list, from what the tab holds now. */
    internal suspend fun DashboardViewModel.dotNewest(): Map<VaultViewMode, Long> {
        val events = allEventsMutex.withLock { allEvents.map { it.kind to it.createdAt } }
        return VaultDots.newest(events, RELAY_TAB_NOTE_KINDS, System.currentTimeMillis() / 1000)
    }

    /** Lights the dot on each list that got something new while you were elsewhere. */
    internal fun DashboardViewModel.refreshDots(newest: Map<VaultViewMode, Long>) {
        val lit = VaultDots.lit(newest, dotSeenAt, watchedMode(), configStore.config.value.zapsOnlyMode)
        if (!_newActivity.value.containsAll(lit)) _newActivity.value = _newActivity.value + lit
    }

    /** Clears [list]'s dot and moves its seen mark up to what it holds now. */
    internal fun DashboardViewModel.markListViewed(list: VaultViewMode) {
        if (list == VaultViewMode.FOLLOWERS) {
            markFollowersSeen()
            return
        }
        _newActivity.value = _newActivity.value - list
        if (dotSeenAt.isEmpty()) return
        viewModelScope.launch(Dispatchers.Main.immediate) {
            val newest = dotNewest()
            if (dotSeenAt.isNotEmpty()) dotSeenAt[list] = newest.getValue(list)
        }
    }

    // ── Connection helpers ────────────────────────────────────────

    fun DashboardViewModel.setViewMode(mode: VaultViewMode) {
        _viewMode.value = mode
        maxDisplayedItems = 50
        scheduleUpdateDisplayData()
        when (mode) {
            VaultViewMode.LIKES -> {
                armLikesSettle()
                fetchMissingLikedNotes()
            }
            VaultViewMode.ZAPS -> {
                armZapsSettle()
                fetchMoreZapReceipts()
                fetchMissingZappedNotes()
            }
            VaultViewMode.FOLLOWERS -> viewModelScope.launch { refreshFollowers() }
            else -> {}
        }
    }

    /**
     * The list and scope on show before Android killed the app, so the tab
     * comes back where it was. Set straight, without setViewMode's fetches:
     * nothing has loaded yet. A notification consumed after this still picks
     * its own list (applyRelayFocusView).
     */
    internal fun DashboardViewModel.restoreSavedMode() {
        savedState.get<String>(SAVED_VIEW_MODE)
            ?.let { name -> VaultViewMode.entries.firstOrNull { it.name == name } }
            ?.let { _viewMode.value = it }
        if (_viewMode.value == VaultViewMode.LIKES) armLikesSettle()
        savedState.get<String>(SAVED_NOTE_SCOPE)
            ?.let { name -> VaultNoteScope.entries.firstOrNull { it.name == name } }
            ?.let { _noteScope.value = it }
        _recipesOnly.value = _noteScope.value == VaultNoteScope.ARTICLES && savedState.get<Boolean>(SAVED_RECIPES) == true
        viewModelScope.launch {
            kotlinx.coroutines.flow.combine(_viewMode, _noteScope, _recipesOnly) { mode, scope, recipes ->
                Triple(mode, scope, recipes)
            }.collect { (mode, scope, recipes) ->
                savedState[SAVED_VIEW_MODE] = mode.name
                savedState[SAVED_NOTE_SCOPE] = scope.name
                savedState[SAVED_RECIPES] = recipes
            }
        }
    }

    fun DashboardViewModel.setNoteScope(scope: VaultNoteScope) {
        if (scope != VaultNoteScope.ARTICLES) _recipesOnly.value = false
        if (_noteScope.value == scope) return
        _noteScope.value = scope
        maxDisplayedItems = 50
        _notesHasLoadedOnce.value = false
        scheduleUpdateDisplayData()
    }

    fun DashboardViewModel.toggleRecipesOnly() {
        if (_noteScope.value != VaultNoteScope.ARTICLES) return
        _recipesOnly.value = !_recipesOnly.value
        maxDisplayedItems = 50
        scheduleUpdateDisplayData()
    }

    fun DashboardViewModel.setContentFilter(filter: VaultContentFilter) {
        _contentFilter.value = filter
        maxDisplayedItems = 50
        _notesHasLoadedOnce.value = false
        scheduleUpdateDisplayData()
    }

    fun DashboardViewModel.setLikesFilter(filter: VaultLikesFilter) {
        _likesFilter.value = filter
        maxDisplayedItems = 50
        _likesHasLoadedOnce.value = false
        armLikesSettle()
        scheduleUpdateDisplayData()
        if (filter == VaultLikesFilter.MY_LIKES) fetchMissingLikedNotes()
    }

    fun DashboardViewModel.setZapsFilter(filter: VaultZapsFilter) {
        _zapsFilter.value = filter
        maxDisplayedItems = 50
        _zapsHasLoadedOnce.value = false
        armZapsSettle()
        scheduleUpdateDisplayData()
        if (filter == VaultZapsFilter.MY_ZAPS) fetchMissingZappedNotes()
    }

    fun DashboardViewModel.setFollowersFilter(filter: VaultFollowersFilter) {
        _followersFilter.value = filter
        fetchFollowerProfiles()
    }

    // ── Followers ────────────────────────────────────────────────

    /** The list in sight; see [VaultDots.watchedMode]. */
    internal fun DashboardViewModel.watchedMode(): VaultViewMode? = VaultDots.watchedMode(
        com.nostrvault.ui.navigation.VaultSection.showsMedia.value, _viewMode.value, _noteScope.value,
    )

    internal fun DashboardViewModel.markFollowersSeen() {
        followersSeenStore.markSeen(nostrService.activeHexPubkey)
        _hasNewFollowers.value = false
    }

    internal fun DashboardViewModel.fetchFollowerProfiles() {
        val snapshot = _followerSnapshot.value ?: return
        val shown = snapshot.entries(_followersFilter.value).take(300).map { it.pubkey }
        if (shown.isNotEmpty()) nostrService.fetchMissingProfiles(shown)
    }

    // ── Notification focus (port of iOS consumeRelayFocus, PR #95) ──
