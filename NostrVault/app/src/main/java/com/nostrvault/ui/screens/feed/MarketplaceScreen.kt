package com.nostrvault.ui.screens.feed

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.MarketCategory
import com.nostrvault.data.model.MarketListing
import com.nostrvault.relay.HavenBridge
import com.nostrvault.ui.theme.CardBackground
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.TertiaryText

/**
 * Marketplace feed (port of the iPhone's Marketplace grid, itself after the
 * MyNostrSpace marketplace): category chips over a two-column grid of square
 * photo cards with title, price and seller.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun MarketplaceGrid(
    listings: List<MarketListing>,
    selectedCategory: MarketCategory?,
    profiles: Map<String, FeedProfile>,
    isLoading: Boolean,
    contentPadding: PaddingValues,
    onSelectCategory: (MarketCategory?) -> Unit,
    onListingClick: (MarketListing) -> Unit,
    onRefresh: () -> Unit,
    onNeedProfiles: (List<String>) -> Unit,
    onAppear: () -> Unit,
    followSetIsEmpty: Boolean = false,
    /** No relay answered the last load. */
    loadFailed: Boolean = false,
    scopeFollowing: Boolean = false,
    onShowGlobal: () -> Unit = {},
) {
    val colors = LocalNostrVaultColors.current
    // Switching modes loads too, but a launch that restores Marketplace as the
    // default feed never goes through a switch.
    LaunchedEffect(Unit) { onAppear() }
    if (listings.isEmpty()) {
        Box(contentAlignment = Alignment.Center, modifier = Modifier.fillMaxSize()) {
            if (isLoading) {
                CircularProgressIndicator(color = colors.primary)
            } else {
                ScopedEmptyPlaceholder(
                    FeedMode.MARKETPLACE,
                    scopeFollowing = scopeFollowing,
                    onRefresh = onRefresh,
                    onShowGlobal = onShowGlobal,
                    subtitleOverride = if (followSetIsEmpty) "You don't follow anyone yet. Switch to Global to see every listing." else null,
                    loadFailed = loadFailed,
                )
            }
        }
        return
    }

    // Sellers are mostly strangers, so their names are not in the profile
    // cache yet. Ask once per distinct set rather than per card.
    val sellers = remember(listings) { listings.map { it.pubkey }.distinct() }
    LaunchedEffect(sellers) { onNeedProfiles(sellers) }

    val categories = remember(listings) {
        val present = listings.mapTo(HashSet()) { it.category }
        MarketCategory.entries.filter { it in present }
    }
    val visible = remember(listings, selectedCategory) {
        if (selectedCategory == null) listings else listings.filter { it.category == selectedCategory }
    }

    PullToRefreshBox(isRefreshing = isLoading, onRefresh = onRefresh, modifier = Modifier.fillMaxSize()) {
        LazyVerticalGrid(
            // As many 160dp cards as fit (iOS adaptive(minimum: 160)): two on a phone, more on a tablet.
            columns = GridCells.Adaptive(minSize = 160.dp),
            contentPadding = PaddingValues(
                start = 12.dp,
                end = 12.dp,
                top = contentPadding.calculateTopPadding(),
                bottom = contentPadding.calculateBottomPadding() + 12.dp,
            ),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.fillMaxSize(),
        ) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                CategoryChips(categories, selectedCategory, onSelectCategory)
            }
            items(visible, key = { "${it.kind}:${it.pubkey}:${it.dTag ?: it.id}" }) { listing ->
                ListingCard(listing, profiles[listing.pubkey], onClick = { onListingClick(listing) })
            }
        }
    }
}

@Composable
private fun CategoryChips(
    categories: List<MarketCategory>,
    selected: MarketCategory?,
    onSelect: (MarketCategory?) -> Unit,
) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(vertical = 4.dp),
    ) {
        Chip("All", selected == null) { onSelect(null) }
        categories.forEach { category ->
            Chip(category.displayName, selected == category) { onSelect(category) }
        }
    }
}

@Composable
private fun Chip(label: String, isSelected: Boolean, onClick: () -> Unit) {
    val colors = LocalNostrVaultColors.current
    Text(
        text = label,
        color = if (isSelected) Color.Black else PrimaryText,
        fontSize = 13.sp,
        fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal,
        modifier = Modifier
            .clip(CircleShape)
            .background(if (isSelected) colors.primary else CardBackground)
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 7.dp),
    )
}

@Composable
internal fun ListingCard(listing: MarketListing, seller: FeedProfile?, onClick: () -> Unit) {
    val colors = LocalNostrVaultColors.current
    Column(modifier = Modifier.clickable(onClick = onClick)) {
        Box {
            AsyncImage(
                model = listing.coverImage,
                contentDescription = listing.title,
                contentScale = ContentScale.Crop,
                modifier = Modifier
                    .fillMaxWidth()
                    .aspectRatio(1f)
                    .clip(RoundedCornerShape(10.dp))
                    .background(CardBackground),
            )
            if (listing.isAuction) {
                Text(
                    text = "Auction",
                    color = Color.Black,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier
                        .padding(8.dp)
                        .clip(CircleShape)
                        .background(colors.primary)
                        .padding(horizontal = 8.dp, vertical = 3.dp),
                )
            }
        }
        Spacer(Modifier.height(6.dp))
        Text(
            text = listing.title,
            color = PrimaryText,
            fontSize = 14.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            text = listing.priceLabel,
            color = colors.primaryLight,
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            text = sellerName(listing.pubkey, seller),
            color = TertiaryText,
            fontSize = 12.sp,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

internal fun sellerName(pubkey: String, profile: FeedProfile?): String =
    profile?.bestName ?: (HavenBridge.encodeNpub(pubkey)?.take(12)?.plus("…") ?: pubkey.take(8))
