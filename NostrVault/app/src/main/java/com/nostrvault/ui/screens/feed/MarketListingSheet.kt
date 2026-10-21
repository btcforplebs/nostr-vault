package com.nostrvault.ui.screens.feed

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Gavel
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.LocalOffer
import androidx.compose.material.icons.outlined.Place
import androidx.compose.material.icons.outlined.ShoppingCart
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.MarketCategory
import com.nostrvault.data.model.MarketListing
import com.nostrvault.data.model.toNote
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.components.BroadcastSheet
import com.nostrvault.ui.navigation.LocalMessageUser
import com.nostrvault.ui.theme.CardBackground
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent
import kotlinx.coroutines.launch

@EntryPoint
@InstallIn(SingletonComponent::class)
interface MarketListingEntryPoint {
    fun feedService(): FeedService
    fun nostrService(): NostrService
    fun configStore(): ConfigStore
}

/**
 * A listing opened from the grid, a profile's Shop or a quoted post: a
 * full-height sheet titled "Listing" or "Auction" with Done and an Event Info
 * button, photos edge to edge, price, what and where, the seller, the
 * description, and where to buy it. Nostr Vault doesn't run a checkout, so
 * buying hands off to Plebeian Market, or the buyer messages the seller.
 * Shopstr was linked too until 2026-10-04, when Logen reported it dead.
 * iOS `MarketplaceListingSheet`.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
internal fun MarketListingSheet(
    listing: MarketListing,
    seller: FeedProfile?,
    /** Null leaves the seller card without a tap or chevron (iOS `onOpenProfile` nil). */
    onOpenSeller: ((String) -> Unit)?,
    /**
     * Opens a message to the seller. Null falls back to the nav host's
     * [LocalMessageUser]. Never offered on your own listing.
     */
    onMessageSeller: ((MarketListing) -> Unit)? = null,
    /** Null shows Event Info over this sheet, as iOS does. */
    onEventInfo: ((MarketListing) -> Unit)? = null,
    onDismiss: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    val uriHandler = LocalUriHandler.current
    val context = LocalContext.current
    val services = remember(context) {
        EntryPointAccessors.fromApplication(context.applicationContext, MarketListingEntryPoint::class.java)
    }
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    val close: () -> Unit = { scope.launch { sheetState.hide() }.invokeOnCompletion { onDismiss() } }
    var showingEventInfo by remember { mutableStateOf(false) }

    val messageUser = LocalMessageUser.current
    val message: ((MarketListing) -> Unit)? = when {
        !showsMessageSeller(listing.pubkey, services.nostrService().activeHexPubkey) -> null
        onMessageSeller != null -> onMessageSeller
        messageUser != null -> { l -> onDismiss(); messageUser(l.pubkey, l.messageToSeller) }
        else -> null
    }

    // The background is a hard-coded near-black until a sheet token lands [Tara].
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = Color(0xFF0B0B0B),
        dragHandle = null,
    ) {
        Column(Modifier.fillMaxWidth().fillMaxHeight()) {
            ListingTopBar(
                title = if (listing.isAuction) "Auction" else "Listing",
                onDone = close,
                onInfo = {
                    if (onEventInfo != null) onEventInfo(listing) else showingEventInfo = true
                },
            )
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f)
                    .verticalScroll(rememberScrollState())
                    .navigationBarsPadding()
                    .padding(bottom = 28.dp),
                verticalArrangement = Arrangement.spacedBy(18.dp),
            ) {
                ListingPhotos(listing)
                Column(
                    modifier = Modifier.padding(horizontal = 20.dp),
                    verticalArrangement = Arrangement.spacedBy(18.dp),
                ) {
                    ListingHeader(listing)
                    SellerCard(listing.pubkey, seller, onOpenSeller)
                    if (listing.summary.isNotEmpty()) {
                        SelectionContainer {
                            Text(
                                listing.summary,
                                color = PrimaryText,
                                fontSize = 15.sp,
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }
                    }
                    Column(
                        verticalArrangement = Arrangement.spacedBy(10.dp),
                        modifier = Modifier.padding(top = 4.dp),
                    ) {
                        ListingButton(
                            label = if (listing.isAuction) "Bid on Plebeian" else "Buy on Plebeian",
                            icon = if (listing.isAuction) Icons.Filled.Gavel else Icons.Outlined.ShoppingCart,
                            filled = true,
                            onClick = { runCatching { uriHandler.openUri(listing.plebeianUrl) } },
                        )
                        if (message != null) {
                            ListingButton(
                                label = "Message seller",
                                icon = NostrVaultIcons.ReplyAction,
                                filled = false,
                                onClick = { message(listing) },
                            )
                        }
                    }
                }
            }
        }
    }

    if (showingEventInfo) {
        BroadcastSheet(
            note = remember(listing.id) { listing.toNote() },
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
            feedService = services.feedService(),
            nostrService = services.nostrService(),
            configStore = services.configStore(),
            onDismiss = { showingEventInfo = false },
            onProfileClick = onOpenSeller?.let { open -> { pubkey: String -> showingEventInfo = false; open(pubkey) } },
        )
    }
}

/** Done on the left, the title centred, Event Info on the right (iOS toolbar). */
@Composable
private fun ListingTopBar(title: String, onDone: () -> Unit, onInfo: () -> Unit) {
    val accent = LocalNostrVaultColors.current.primary
    Box(Modifier.fillMaxWidth().height(52.dp).padding(horizontal = 8.dp)) {
        TextButton(onClick = onDone, modifier = Modifier.align(Alignment.CenterStart)) {
            Text("Done", color = accent, fontSize = 17.sp)
        }
        Text(
            title,
            color = PrimaryText,
            fontSize = 17.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
            textAlign = TextAlign.Center,
            modifier = Modifier.align(Alignment.Center),
        )
        IconButton(onClick = onInfo, modifier = Modifier.align(Alignment.CenterEnd)) {
            Icon(Icons.Outlined.Info, contentDescription = "Event Info", tint = accent)
        }
    }
}

/** Square photos edge to edge, swiped, with page dots when there is more than one. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ListingPhotos(listing: MarketListing) {
    val frame = Modifier.fillMaxWidth().heightIn(max = 520.dp).aspectRatio(1f)
    if (listing.images.isEmpty()) {
        MarketplaceImagePlaceholder(frame)
        return
    }
    val pager = rememberPagerState { listing.images.size }
    Box {
        HorizontalPager(state = pager) { page ->
            AsyncImage(
                model = listing.images[page],
                contentDescription = listing.title,
                contentScale = ContentScale.Crop,
                modifier = frame.background(CardBackground),
            )
        }
        if (listing.images.size > 1) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(bottom = 12.dp),
            ) {
                repeat(listing.images.size) { i ->
                    Box(
                        Modifier
                            .size(7.dp)
                            .clip(CircleShape)
                            .background(if (i == pager.currentPage) Color.White else Color.White.copy(alpha = 0.35f)),
                    )
                }
            }
        }
    }
}

@Composable
private fun ListingHeader(listing: MarketListing) {
    val colors = LocalNostrVaultColors.current
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(listing.title, color = PrimaryText, fontSize = 22.sp, fontWeight = FontWeight.Bold)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(listing.priceLabel, color = colors.primary, fontSize = 20.sp, fontWeight = FontWeight.ExtraBold)
            if (listing.isAuction) MarketplaceAuctionBadge()
        }
        val details = listOfNotNull(
            listing.category.takeIf { it != MarketCategory.OTHER }?.let { Icons.Outlined.LocalOffer to it.displayName },
            listing.location?.let { Icons.Outlined.Place to it },
        )
        if (details.isNotEmpty()) {
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                details.forEach { (icon, text) ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(icon, contentDescription = null, tint = SecondaryText, modifier = Modifier.size(14.dp))
                        Spacer(Modifier.width(4.dp))
                        Text(text, color = SecondaryText, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
        }
    }
}

/** "Sold by" and the seller, in a card; a chevron when it opens their profile. */
@Composable
private fun SellerCard(pubkey: String, seller: FeedProfile?, onOpenSeller: ((String) -> Unit)?) {
    val name = sellerName(pubkey, seller)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(CardBackground)
            .clickable(enabled = onOpenSeller != null) { onOpenSeller?.invoke(pubkey) }
            .padding(12.dp),
    ) {
        AvatarImage(url = seller?.pictureURL, pubkey = pubkey, size = 32.dp, displayName = name)
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text("Sold by", color = SecondaryText, fontSize = 11.sp)
            Text(name, color = PrimaryText, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        if (onOpenSeller != null) {
            Icon(NostrVaultIcons.Navigate, contentDescription = null, tint = SecondaryText, modifier = Modifier.size(16.dp))
        }
    }
}

/** Buy/Bid (filled) or Message seller (outlined), full width. */
@Composable
private fun ListingButton(label: String, icon: ImageVector, filled: Boolean, onClick: () -> Unit) {
    val accent = LocalNostrVaultColors.current.primary
    val shape = RoundedCornerShape(12.dp)
    val content = if (filled) Color.White else accent
    Row(
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .then(if (filled) Modifier.background(accent) else Modifier.border(1.5.dp, accent, shape))
            .clickable(onClick = onClick)
            .padding(vertical = 13.dp),
    ) {
        Icon(icon, contentDescription = null, tint = content, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(8.dp))
        Text(label, color = content, fontSize = 15.sp, fontWeight = if (filled) FontWeight.Bold else FontWeight.SemiBold)
    }
}
