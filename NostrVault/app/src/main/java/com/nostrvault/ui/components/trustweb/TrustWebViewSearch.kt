package com.nostrvault.ui.components

import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.TrustMap

@Composable
internal fun ColumnScope.TrustWebViewSearch(
    query: String,
    onQueryChange: (String) -> Unit,
    onFocusChange: (Boolean) -> Unit,
    onSearch: () -> Unit,
    onClear: () -> Unit,
    accent: Color,
    hits: List<TrustMap.PersonHit>,
    me: String,
    searchingRelays: Boolean,
    pasted: String?,
    profiles: Map<String, FeedProfile>,
    name: (String) -> String,
    onPick: (String) -> Unit,
    bottomInset: Dp,
) {
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }
    SearchField(
        query = query,
        onQueryChange = onQueryChange,
        onFocusChange = onFocusChange,
        onSearch = onSearch,
        onClear = onClear,
        accent = accent,
        modifier = Modifier.focusRequester(focus),
    )
    if (query.isNotBlank()) {
        // Above the keyboard when it's up, else above the tab bar.
        val ime = WindowInsets.ime.asPaddingValues().calculateBottomPadding()
        SearchResults(
            query = query.trim(),
            hits = hits,
            me = me,
            searching = searchingRelays && pasted == null,
            profiles = profiles,
            name = name,
            accent = accent,
            onPick = onPick,
            modifier = Modifier
                .weight(1f, fill = false)
                .padding(bottom = maxOf(ime, bottomInset) + 8.dp),
        )
    }
}
