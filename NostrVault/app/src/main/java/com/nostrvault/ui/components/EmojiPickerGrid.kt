package com.nostrvault.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.EmojiEmotions
import androidx.compose.material.icons.outlined.EmojiEvents
import androidx.compose.material.icons.outlined.EmojiFlags
import androidx.compose.material.icons.outlined.EmojiFoodBeverage
import androidx.compose.material.icons.outlined.EmojiNature
import androidx.compose.material.icons.outlined.EmojiObjects
import androidx.compose.material.icons.outlined.EmojiPeople
import androidx.compose.material.icons.outlined.EmojiSymbols
import androidx.compose.material.icons.outlined.EmojiTransportation
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.StarOutline
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.local.ReactionPick
import com.nostrvault.ui.components.EmojiPickerSections.Kind
import com.nostrvault.ui.components.EmojiPickerSections.Section
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PlaceholderText
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.TertiaryGroupedBg
import kotlinx.coroutines.launch

/**
 * The emoji picker's body, shared by the reaction sheet and the composer's
 * emoji panel: a search pill, a strip of section icons that follows the
 * scroll and jumps on tap, and one grid with a header per section.
 */
@Composable
internal fun EmojiPickerGrid(
    sections: List<Section>,
    names: Map<String, String>,
    onPick: (ReactionPick) -> Unit,
    gridHeight: Dp,
    modifier: Modifier = Modifier,
    onSearchFocusChange: (Boolean) -> Unit = {},
) {
    val colors = LocalNostrVaultColors.current
    var query by rememberSaveable { mutableStateOf("") }
    val results = remember(query, sections, names) { EmojiPickerSections.search(sections, names, query) }
    val gridState = rememberLazyGridState()
    val stripState = rememberLazyListState()
    val scope = rememberCoroutineScope()

    // Where each section's header sits in the grid: one header item, then its emoji.
    val starts = remember(sections) {
        var at = 0
        sections.map { s -> at.also { at += 1 + s.picks.size } }
    }
    val current by remember(starts) {
        derivedStateOf {
            val first = gridState.firstVisibleItemIndex
            starts.indexOfLast { it <= first }.coerceAtLeast(0)
        }
    }
    LaunchedEffect(current) { if (sections.isNotEmpty()) stripState.animateScrollToItem(current) }

    Column(modifier.fillMaxWidth()) {
        SearchPill(query, { query = it }, onSearchFocusChange)
        Spacer(Modifier.height(8.dp))

        if (query.isBlank()) {
            LazyRow(
                state = stripState,
                horizontalArrangement = Arrangement.spacedBy(2.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                itemsIndexed(sections) { index, section ->
                    val selected = index == current
                    Box(
                        contentAlignment = Alignment.Center,
                        modifier = Modifier
                            .size(36.dp)
                            .clip(CircleShape)
                            .then(if (selected) Modifier.background(colors.primary.copy(alpha = 0.18f)) else Modifier)
                            .semantics {
                                contentDescription = section.title
                                this.selected = selected
                            }
                            .clickable { scope.launch { gridState.scrollToItem(starts[index]) } },
                    ) {
                        val icon = section.icon
                        if (icon != null) {
                            ReactionGlyph(icon.content, icon.custom, fontSize = 16.sp)
                        } else {
                            Icon(
                                sectionIcon(section),
                                contentDescription = null,
                                tint = if (selected) colors.primary else SecondaryText,
                                modifier = Modifier.size(20.dp),
                            )
                        }
                    }
                }
            }
            Spacer(Modifier.height(4.dp))
        }

        LazyVerticalGrid(
            state = gridState,
            columns = GridCells.Adaptive(minSize = 44.dp),
            modifier = Modifier
                .fillMaxWidth()
                .height(gridHeight),
        ) {
            if (query.isNotBlank()) {
                if (results.isEmpty()) {
                    item(span = { GridItemSpan(maxLineSpan) }) {
                        Text(
                            "No emoji found",
                            color = SecondaryText,
                            fontSize = 14.sp,
                            modifier = Modifier.padding(vertical = 24.dp),
                        )
                    }
                }
                items(results) { pick -> EmojiCell(pick, names, onPick) }
            } else {
                sections.forEach { section ->
                    item(span = { GridItemSpan(maxLineSpan) }) {
                        Text(
                            section.title,
                            color = SecondaryText,
                            fontSize = 12.sp,
                            fontWeight = FontWeight.SemiBold,
                            modifier = Modifier
                                .padding(start = 4.dp, top = 10.dp, bottom = 4.dp)
                                .semantics { heading() },
                        )
                    }
                    items(section.picks) { pick -> EmojiCell(pick, names, onPick) }
                }
            }
        }
    }
}

@Composable
private fun EmojiCell(pick: ReactionPick, names: Map<String, String>, onPick: (ReactionPick) -> Unit) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .aspectRatio(1f)
            .clip(CircleShape)
            .semantics { contentDescription = pick.shortcode ?: names[pick.content] ?: pick.content }
            .clickable { onPick(pick) },
    ) {
        ReactionGlyph(pick.content, pick.custom, fontSize = 26.sp)
    }
}

@Composable
private fun SearchPill(query: String, onQuery: (String) -> Unit, onFocusChange: (Boolean) -> Unit) {
    val colors = LocalNostrVaultColors.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .height(38.dp)
            .clip(RoundedCornerShape(19.dp))
            .background(TertiaryGroupedBg)
            .padding(horizontal = 12.dp),
    ) {
        Icon(NostrVaultIcons.Search, contentDescription = null, tint = SecondaryText, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(8.dp))
        Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
            if (query.isEmpty()) Text("Search emoji", color = PlaceholderText, fontSize = 15.sp)
            BasicTextField(
                value = query,
                onValueChange = onQuery,
                singleLine = true,
                textStyle = TextStyle(color = PrimaryText, fontSize = 15.sp),
                cursorBrush = SolidColor(colors.primary),
                modifier = Modifier
                    .fillMaxWidth()
                    .semantics { contentDescription = "Search emoji" }
                    .onFocusChanged { onFocusChange(it.isFocused) },
            )
        }
        if (query.isNotEmpty()) {
            Icon(
                Icons.Filled.Close,
                contentDescription = "Clear search",
                tint = SecondaryText,
                modifier = Modifier
                    .size(28.dp)
                    .clip(CircleShape)
                    .clickable { onQuery("") }
                    .padding(6.dp),
            )
        }
    }
}

private fun sectionIcon(section: Section): ImageVector = when (section.kind) {
    Kind.RECENT -> Icons.Outlined.Schedule
    Kind.YOURS, Kind.PACK -> Icons.Outlined.StarOutline
    Kind.UNICODE -> when (section.title) {
        "Smileys & Emotion" -> Icons.Outlined.EmojiEmotions
        "People & Body" -> Icons.Outlined.EmojiPeople
        "Animals & Nature" -> Icons.Outlined.EmojiNature
        "Food & Drink" -> Icons.Outlined.EmojiFoodBeverage
        "Travel & Places" -> Icons.Outlined.EmojiTransportation
        "Activities" -> Icons.Outlined.EmojiEvents
        "Objects" -> Icons.Outlined.EmojiObjects
        "Symbols" -> Icons.Outlined.EmojiSymbols
        "Flags" -> Icons.Outlined.EmojiFlags
        else -> Icons.Outlined.EmojiEmotions
    }
}
