package com.nostrvault.ui.screens.feed

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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Gavel
import androidx.compose.material.icons.outlined.ShoppingBag
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.MarketCategory
import com.nostrvault.data.model.MarketListing
import com.nostrvault.ui.theme.CardBackground
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.SeparatorColor

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
                    // iOS says the same thing whether you follow nobody or nobody sells.
                    scopeFollowing = scopeFollowing || followSetIsEmpty,
                    onRefresh = onRefresh,
                    onShowGlobal = onShowGlobal,
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
            Chip(category.displayName, selected == category) { onSelect(toggledCategory(selected, category)) }
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
    val shape = RoundedCornerShape(12.dp)
    // One rounded box around the photo and the text, as iOS MarketplaceCardView.
    Column(
        modifier = Modifier
            .clip(shape)
            .background(CardBackground)
            .border(0.5.dp, SeparatorColor, shape)
            .clickable(onClick = onClick),
    ) {
        Box {
            val photo = Modifier.fillMaxWidth().aspectRatio(1f)
            if (listing.coverImage != null) {
                AsyncImage(
                    model = listing.coverImage,
                    contentDescription = listing.title,
                    contentScale = ContentScale.Crop,
                    modifier = photo,
                )
            } else {
                MarketplaceImagePlaceholder(photo)
            }
            if (listing.isAuction) {
                MarketplaceAuctionBadge(Modifier.padding(8.dp))
            }
        }
        Column(Modifier.padding(10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                text = listing.title,
                color = PrimaryText,
                fontSize = 14.sp,
                fontWeight = FontWeight.Bold,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.fillMaxWidth(),
            )
            Text(
                text = listing.priceLabel,
                color = colors.primary,
                fontSize = 14.sp,
                fontWeight = FontWeight.ExtraBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = sellerName(listing.pubkey, seller),
                color = SecondaryText,
                fontSize = 11.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/** A listing without a photo: a bag on pale accent. iOS MarketplaceImagePlaceholder. */
@Composable
internal fun MarketplaceImagePlaceholder(modifier: Modifier = Modifier) {
    val colors = LocalNostrVaultColors.current
    Box(contentAlignment = Alignment.Center, modifier = modifier.background(colors.primaryPale)) {
        Icon(
            Icons.Outlined.ShoppingBag,
            contentDescription = null,
            tint = colors.primary.copy(alpha = 0.7f),
            modifier = Modifier.size(28.dp),
        )
    }
}

/** Hammer and "Auction", white on the accent. iOS MarketplaceAuctionBadge. */
@Composable
internal fun MarketplaceAuctionBadge(modifier: Modifier = Modifier) {
    val colors = LocalNostrVaultColors.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .clip(CircleShape)
            .background(colors.primary)
            .padding(horizontal = 8.dp, vertical = 4.dp),
    ) {
        Icon(Icons.Filled.Gavel, contentDescription = null, tint = Color.White, modifier = Modifier.size(11.dp))
        Spacer(Modifier.width(4.dp))
        Text("Auction", color = Color.White, fontSize = 10.sp, fontWeight = FontWeight.Bold)
    }
}

/** A seller's name, or "npub…" and the last six of their key (iOS). */
internal fun sellerName(pubkey: String, profile: FeedProfile?): String =
    profile?.bestName ?: sellerFallbackName(pubkey)

internal fun sellerFallbackName(pubkey: String): String = "npub…" + pubkey.takeLast(6)

/** A tap on a category chip: the selected one clears back to All (iOS). */
internal fun toggledCategory(selected: MarketCategory?, tapped: MarketCategory): MarketCategory? =
    if (selected == tapped) null else tapped

/** Message seller is never offered on your own listing (iOS). */
internal fun showsMessageSeller(sellerPubkey: String, activeHexPubkey: String): Boolean =
    sellerPubkey != activeHexPubkey
