package com.nostrvault.ui.components

import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue

/**
 * Puts [listState] back at the top when [key] changes (not on first show): an
 * account chip switch opens the new list at its top instead of the old list's
 * scroll offset over different rows (Logen 2026-11-14).
 */
@Composable
fun ScrollTopOnChange(listState: LazyListState, key: Any?) {
    var last by remember { mutableStateOf(key) }
    LaunchedEffect(key) {
        if (last != key) listState.requestScrollToItem(0)
        last = key
    }
}
