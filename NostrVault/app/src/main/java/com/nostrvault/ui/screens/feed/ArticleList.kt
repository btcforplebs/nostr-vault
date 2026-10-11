package com.nostrvault.ui.screens.feed

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.flow.first
import androidx.compose.ui.text.style.TextOverflow
import coil.compose.AsyncImage
import com.nostrvault.data.model.ArticleMeta
import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.RecipeTopics
import com.nostrvault.ui.theme.*
import java.text.DateFormat

// ── Media grid ───────────────────────────────────────────────────

/**
 * Instagram-style 3-column media grid for FeedMode.MEDIA (iOS parity with
 * FeedView.mediaGridView). Each cell shows a note's first media URL as a square
 * thumbnail; tapping opens a full-screen swipeable pager across every cell's
 * media, and long-pressing opens the note's detail view.
 */
@OptIn(ExperimentalFoundationApi::class)
/**
 * The Articles mode list: one card per long-form post, drawn from tags only so
 * a 20,000-word body never gets laid out to render a row. Tapping opens the
 * reader rather than the note screen — the note screen renders kind-1 threads,
 * and would show the Markdown source.
 */
@Composable
internal fun ArticleList(
    mode: FeedMode,
    notes: List<FeedNote>,
    profiles: Map<String, FeedProfile>,
    isRefreshing: Boolean,
    contentPadding: PaddingValues,
    onArticleClick: (String) -> Unit,
    onRefresh: () -> Unit,
    scopeFollowing: Boolean = false,
    onShowGlobal: () -> Unit = {},
    /** Recipes: no relay answered, so the empty grid says so. */
    loadFailed: Boolean = false,
) {
    if (notes.isEmpty()) {
        if (!isRefreshing) ScopedEmptyPlaceholder(mode, scopeFollowing, onRefresh, onShowGlobal, loadFailed = loadFailed)
        return
    }

    val colors = LocalNostrVaultColors.current
    // Recipes: category chips from the zapcooking-<category> tags in the
    // loaded results, not a fixed list. iOS: RecipeCategoryBar.
    val isRecipes = mode == FeedMode.RECIPES
    val categories = remember(notes, isRecipes) { if (isRecipes) RecipeTopics.topCategories(notes) else emptyList() }
    var category by rememberSaveable(mode) { mutableStateOf<String?>(null) }
    // A category can vanish when the results change under the chip; check
    // every category present, not just the capped chip list.
    LaunchedEffect(notes, category) {
        val c = category ?: return@LaunchedEffect
        if (notes.none { c in RecipeTopics.categoriesOf(it.tags) }) category = null
    }
    val shown = remember(notes, category) { RecipeTopics.filter(notes, category) }
    // Recipes are image-forward: a grid of photo tiles, like iOS's
    // LazyVGrid(.adaptive(minimum: 150)) of RecipeCardView.
    if (isRecipes) {
        LazyVerticalGrid(
            columns = GridCells.Adaptive(minSize = 150.dp),
            contentPadding = PaddingValues(
                start = 16.dp,
                end = 16.dp,
                top = contentPadding.calculateTopPadding(),
                bottom = contentPadding.calculateBottomPadding() + 16.dp,
            ),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.fillMaxSize(),
        ) {
            if (categories.isNotEmpty()) item(key = "recipe-categories", span = { GridItemSpan(maxLineSpan) }) {
                // The grid already insets 16dp, so the chip row adds none.
                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier
                        .fillMaxWidth()
                        .horizontalScroll(rememberScrollState())
                        .padding(vertical = 8.dp),
                ) {
                    RecipeCategoryChip("All", category == null) { category = null }
                    categories.forEach { name ->
                        RecipeCategoryChip(name.replaceFirstChar { it.titlecase() }, category == name) {
                            category = if (category == name) null else name
                        }
                    }
                }
            }
            items(shown, key = { it.id }) { note ->
                RecipeCard(
                    note = note,
                    authorName = profiles[note.pubkey]?.bestName ?: ("npub…" + note.pubkey.takeLast(6)),
                    onClick = { onArticleClick(note.id) },
                )
            }
        }
        return
    }
    LazyColumn(
        contentPadding = contentPadding,
        modifier = Modifier.fillMaxSize(),
    ) {
        items(shown, key = { it.id }) { note ->
            val meta = remember(note.id, note.tags) { ArticleMeta.from(note) }
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { onArticleClick(note.id) }
                    .padding(horizontal = 16.dp, vertical = 14.dp),
            ) {
                meta.imageUrl?.let { url ->
                    AsyncImage(
                        model = url,
                        contentDescription = null,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(140.dp)
                            .clip(RoundedCornerShape(10.dp)),
                    )
                    Spacer(Modifier.height(10.dp))
                }
                Text(
                    text = meta.title,
                    color = PrimaryText,
                    fontSize = 17.sp,
                    fontWeight = FontWeight.SemiBold,
                    lineHeight = 22.sp,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                meta.summary?.let {
                    Spacer(Modifier.height(6.dp))
                    Text(
                        text = it,
                        color = SecondaryText,
                        fontSize = 14.sp,
                        lineHeight = 19.sp,
                        maxLines = 3,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Spacer(Modifier.height(8.dp))
                Text(
                    text = buildString {
                        append(profiles[note.pubkey]?.bestName ?: note.pubkey.take(8))
                        append(" · ")
                        append(DateFormat.getDateInstance(DateFormat.MEDIUM).format(meta.publishedAt))
                        if (!isRecipes) ArticleMeta.readingTimeMinutes(note.content)?.let { append(" · $it min read") }
                    },
                    color = TertiaryText,
                    fontSize = 12.sp,
                )
            }
            HorizontalDivider(color = colors.primary.copy(alpha = 0.10f))
        }
    }
}

/** One tile in the Recipes grid (iOS RecipeCardView): hero image, title, author. */
@Composable
private fun RecipeCard(note: FeedNote, authorName: String, onClick: () -> Unit) {
    val colors = LocalNostrVaultColors.current
    val meta = remember(note.id, note.tags) { ArticleMeta.from(note) }
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(SecondaryGroupedBg)
            .border(0.5.dp, SeparatorColor, RoundedCornerShape(12.dp))
            .clickable(onClick = onClick),
    ) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .fillMaxWidth()
                .height(130.dp)
                .background(colors.primaryPale),
        ) {
            val url = meta.imageUrl
            if (url != null) {
                AsyncImage(
                    model = url,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize(),
                )
            } else {
                Icon(
                    NostrVaultIcons.Recipes,
                    contentDescription = null,
                    tint = colors.primary.copy(alpha = 0.7f),
                    modifier = Modifier.size(28.dp),
                )
            }
        }
        Column(modifier = Modifier.padding(10.dp)) {
            Text(
                text = meta.title,
                color = PrimaryText,
                fontSize = 14.sp,
                fontWeight = FontWeight.Bold,
                lineHeight = 18.sp,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.height(4.dp))
            Text(
                text = authorName,
                color = SecondaryText,
                fontSize = 11.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
private fun RecipeCategoryChip(title: String, isOn: Boolean, onClick: () -> Unit) {
    val colors = LocalNostrVaultColors.current
    Text(
        text = title,
        color = if (isOn) Color.White else colors.primary,
        fontSize = 12.sp,
        fontWeight = FontWeight.SemiBold,
        modifier = Modifier
            .clip(CircleShape)
            .background(if (isOn) colors.primary else colors.primary.copy(alpha = 0.14f))
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 6.dp),
    )
}
