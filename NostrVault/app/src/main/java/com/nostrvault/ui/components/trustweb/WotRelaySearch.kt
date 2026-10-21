package com.nostrvault.ui.components

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import com.nostrvault.service.NostrService
import kotlinx.coroutines.delay

/**
 * Whether the WOT search asks the relays for [text] (already trimmed): two
 * characters or more, and not a partial npub, which no name will match.
 * iOS `searchRelays`.
 */
internal fun wotSearchesRelays(text: String): Boolean =
    text.length >= 2 && !text.lowercase().startsWith("npub1")

/**
 * Whether an answer or timeout for the search [asked] still belongs to the
 * field's [query], so an older search can't switch off a newer one's spinner.
 * iOS `query.trimmingCharacters(in:) == trimmed`.
 */
internal fun isCurrentWotSearch(asked: String, query: String): Boolean = query.trim() == asked

/**
 * Names not cached yet come from the relays, after a pause in typing. Their
 * profiles land in the cache, so the local ranking just runs again; nothing
 * here reads the results. A pasted key skips the relays and fetches that one
 * profile. iOS `searchRelays`.
 */
@Composable
internal fun WotRelaySearchEffect(
    query: String,
    pasted: String?,
    nostrService: NostrService,
    onSearching: (Boolean) -> Unit,
) {
    val currentQuery by rememberUpdatedState(query)
    LaunchedEffect(query) {
        val text = query.trim()
        // The last search's answers stop here; this one starts clean.
        nostrService.cancelGlobalSearch(NostrService.SearchCaller.WOT)
        if (pasted != null) {
            onSearching(false)
            nostrService.fetchMissingProfiles(listOf(pasted))
            return@LaunchedEffect
        }
        if (!wotSearchesRelays(text)) {
            onSearching(false)
            return@LaunchedEffect
        }
        onSearching(true)
        delay(WOT_SEARCH_DEBOUNCE_MS)
        nostrService.globalSearch(text, NostrService.SearchCaller.WOT) {
            if (isCurrentWotSearch(text, currentQuery)) onSearching(false)
        }
        // A relay that never answers mustn't leave the spinner on.
        delay(WOT_SEARCH_SPINNER_CAP_MS)
        if (isCurrentWotSearch(text, currentQuery)) onSearching(false)
    }
    DisposableEffect(Unit) {
        onDispose { nostrService.cancelGlobalSearch(NostrService.SearchCaller.WOT) }
    }
}

/** Typing pauses this long before the relays are asked (iOS 350 ms). */
private const val WOT_SEARCH_DEBOUNCE_MS = 350L
/** The "Searching relays…" row gives up after this (iOS 6 s). */
internal const val WOT_SEARCH_SPINNER_CAP_MS = 6_000L
