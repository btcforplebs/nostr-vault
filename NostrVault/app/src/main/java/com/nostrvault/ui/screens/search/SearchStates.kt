package com.nostrvault.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText

// The search screen's non-list states, sized as iOS SearchView+Results and
// SearchView+EmptyState draw them.

/** iOS `Color.secondary.opacity(x)`: the secondary text colour, faded further. */
internal fun searchSecondary(opacity: Float): Color = SecondaryText.copy(alpha = SecondaryText.alpha * opacity)

/** The result tab's icon, shared by the toolbar and the empty-tab state. */
internal val SearchResultFilter.icon: ImageVector
    get() = when (this) {
        SearchResultFilter.ALL -> NostrVaultIcons.Layers
        SearchResultFilter.USERS -> NostrVaultIcons.Profile
        SearchResultFilter.NOTES -> NostrVaultIcons.Document
        SearchResultFilter.HASHTAGS -> NostrVaultIcons.TagIcon
        SearchResultFilter.LINKS -> NostrVaultIcons.LinkIcon
    }

/** Large centred spinner; a pasted note ID says what it is waiting for. */
@Composable
internal fun SearchLoadingState(lookingUpNote: Boolean, accent: Color, modifier: Modifier = Modifier) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically),
        modifier = modifier.fillMaxSize(),
    ) {
        CircularProgressIndicator(color = accent, modifier = Modifier.size(40.dp))
        if (lookingUpNote) {
            Text("Looking up note...", color = SecondaryText, fontSize = 13.sp)
        }
    }
}

@Composable
internal fun SearchNoResultsState(
    showClearFilter: Boolean,
    onClearFilter: () -> Unit,
    accent: Color,
    modifier: Modifier = Modifier,
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
        modifier = modifier.fillMaxSize().padding(16.dp),
    ) {
        Icon(NostrVaultIcons.Search, contentDescription = null, tint = searchSecondary(0.5f), modifier = Modifier.size(32.dp))
        Text("No results found", color = SecondaryText, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
        // The filter, not the query, is what emptied the screen.
        if (showClearFilter) {
            Text(
                "Clear filter",
                color = accent,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.clickable(role = Role.Button, onClick = onClearFilter),
            )
        }
    }
}

/** The query matched something, just not in the open tab; a blank screen there reads as a bug. */
@Composable
internal fun SearchEmptyTabState(filter: SearchResultFilter, query: String) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 24.dp, vertical = 40.dp),
    ) {
        Icon(filter.icon, contentDescription = null, tint = searchSecondary(0.5f), modifier = Modifier.size(26.dp))
        Text(
            "No ${filter.displayName.lowercase()} matched “${query.trim()}”",
            color = SecondaryText,
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
            textAlign = TextAlign.Center,
        )
        Text("Other tabs have results.", color = searchSecondary(0.7f), fontSize = 12.sp)
    }
}

/** Nothing to suggest yet: top-aligned, as iOS draws it under its 60pt inset. */
@Composable
internal fun SearchFallbackState(modifier: Modifier = Modifier) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp)
            .padding(top = 60.dp),
    ) {
        Icon(NostrVaultIcons.Search, contentDescription = null, tint = searchSecondary(0.5f), modifier = Modifier.size(48.dp))
        Spacer(Modifier.height(16.dp))
        Text("Search", color = PrimaryText, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(8.dp))
        Text(
            "Find users, notes, hashtags and links\nOr paste a note1 or nevent1 ID",
            color = SecondaryText,
            fontSize = 13.sp,
            textAlign = TextAlign.Center,
        )
    }
}
