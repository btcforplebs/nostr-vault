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
 * One listing: swipeable photos, price, category and location, seller, the
 * description, then Buy/Bid on Plebeian, Message seller, and Event Info.
 * Shopstr was linked too until 2026-10-04, when Logen reported it dead.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
internal fun MarketListingSheet(
    listing: MarketListing,
    seller: FeedProfile?,
    /** Null hides the tap on the seller row (an embed has nowhere to go). */
    onOpenSeller: ((String) -> Unit)?,
    /** Null hides Message seller (an embed has nowhere to go, or it's yours). */
    onMessageSeller: ((MarketListing) -> Unit)? = null,
    /** Null hides the Event Info button. */
    onEventInfo: ((MarketListing) -> Unit)?,
    onDismiss: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    val uriHandler = LocalUriHandler.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

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
                    .clickable(enabled = onOpenSeller != null) { onOpenSeller?.invoke(listing.pubkey) }
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
                onClick = { runCatching { uriHandler.openUri(listing.plebeianUrl) } },
                colors = ButtonDefaults.buttonColors(containerColor = colors.primary, contentColor = Color.Black),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(if (listing.isAuction) "Bid on Plebeian" else "Buy on Plebeian", fontWeight = FontWeight.SemiBold)
            }
            if (onMessageSeller != null) {
                Spacer(Modifier.height(8.dp))
                OutlinedButton(onClick = { onMessageSeller(listing) }, modifier = Modifier.fillMaxWidth()) {
                    Text("Message seller", color = PrimaryText)
                }
            }
            if (onEventInfo != null) {
                Spacer(Modifier.height(8.dp))
                OutlinedButton(onClick = { onEventInfo(listing) }, modifier = Modifier.fillMaxWidth()) {
                    Icon(NostrVaultIcons.Marketplace, contentDescription = null, tint = PrimaryText, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.size(6.dp))
                    Text("Event Info", color = PrimaryText)
                }
            }
        }
    }
}
