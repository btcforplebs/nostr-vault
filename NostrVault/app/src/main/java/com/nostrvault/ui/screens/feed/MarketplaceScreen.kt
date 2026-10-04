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
import androidx.compose.runtime.remember
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
                EmptyFeedPlaceholder(FeedMode.MARKETPLACE, onRefresh = onRefresh)
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
            columns = GridCells.Fixed(2),
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
private fun ListingCard(listing: MarketListing, seller: FeedProfile?, onClick: () -> Unit) {
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

private fun sellerName(pubkey: String, profile: FeedProfile?): String =
    profile?.bestName ?: (HavenBridge.encodeNpub(pubkey)?.take(12)?.plus("…") ?: pubkey.take(8))

/**
 * One listing: swipeable photos, price, category and location, seller, the
 * description, then Buy/Bid on Plebeian, View on Shopstr, and Event Info.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
internal fun MarketListingSheet(
    listing: MarketListing,
    seller: FeedProfile?,
    onOpenSeller: (String) -> Unit,
    onEventInfo: (MarketListing) -> Unit,
    onDismiss: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    val uriHandler = LocalUriHandler.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val shopstrUrl = remember(listing.id) {
        listing.dTag
            ?.let { HavenBridge.encodeNaddr(it, listing.pubkey, listing.kind) }
            ?.let { "https://shopstr.store/listing/$it" }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, containerColor = Color(0xFF0B0B0B)) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp)
                .navigationBarsPadding()
                .padding(bottom = 16.dp),
        ) {
            val pager = rememberPagerState { listing.images.size }
            Box {
                HorizontalPager(state = pager) { page ->
                    AsyncImage(
                        model = listing.images[page],
                        contentDescription = listing.title,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier
                            .fillMaxWidth()
                            .aspectRatio(1f)
                            .clip(RoundedCornerShape(12.dp))
                            .background(CardBackground),
                    )
                }
                if (listing.images.size > 1) {
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(5.dp),
                        modifier = Modifier
                            .align(Alignment.BottomCenter)
                            .padding(bottom = 10.dp),
                    ) {
                        repeat(listing.images.size) { i ->
                            Box(
                                Modifier
                                    .size(6.dp)
                                    .clip(CircleShape)
                                    .background(if (i == pager.currentPage) Color.White else Color.White.copy(alpha = 0.4f)),
                            )
                        }
                    }
                }
            }

            Spacer(Modifier.height(14.dp))
            Text(listing.title, color = PrimaryText, fontSize = 20.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(4.dp))
            Text(
                text = if (listing.isAuction) "Starting bid ${listing.priceLabel}" else listing.priceLabel,
                color = colors.primaryLight,
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
            )
            val details = listOfNotNull(
                listing.category.takeIf { it != MarketCategory.OTHER }?.displayName,
                listing.location,
            )
            if (details.isNotEmpty()) {
                Spacer(Modifier.height(4.dp))
                Text(details.joinToString(" · "), color = SecondaryText, fontSize = 13.sp)
            }

            Spacer(Modifier.height(12.dp))
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .clip(RoundedCornerShape(8.dp))
                    .clickable { onOpenSeller(listing.pubkey) }
                    .padding(vertical = 4.dp),
            ) {
                AsyncImage(
                    model = seller?.pictureURL,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier
                        .size(28.dp)
                        .clip(CircleShape)
                        .background(CardBackground),
                )
                Spacer(Modifier.size(8.dp))
                Text(sellerName(listing.pubkey, seller), color = PrimaryText, fontSize = 14.sp)
            }

            if (listing.summary.isNotEmpty()) {
                Spacer(Modifier.height(12.dp))
                Text(listing.summary, color = SecondaryText, fontSize = 14.sp, lineHeight = 20.sp)
            }

            Spacer(Modifier.height(18.dp))
            Button(
                onClick = { uriHandler.openUri(listing.plebeianUrl) },
                colors = ButtonDefaults.buttonColors(containerColor = colors.primary, contentColor = Color.Black),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(if (listing.isAuction) "Bid on Plebeian" else "Buy on Plebeian", fontWeight = FontWeight.SemiBold)
            }
            if (shopstrUrl != null) {
                Spacer(Modifier.height(8.dp))
                OutlinedButton(onClick = { uriHandler.openUri(shopstrUrl) }, modifier = Modifier.fillMaxWidth()) {
                    Text("View on Shopstr", color = PrimaryText)
                }
            }
            Spacer(Modifier.height(8.dp))
            OutlinedButton(onClick = { onEventInfo(listing) }, modifier = Modifier.fillMaxWidth()) {
                Icon(NostrVaultIcons.Marketplace, contentDescription = null, tint = PrimaryText, modifier = Modifier.size(16.dp))
                Spacer(Modifier.size(6.dp))
                Text("Event Info", color = PrimaryText)
            }
        }
    }
}
