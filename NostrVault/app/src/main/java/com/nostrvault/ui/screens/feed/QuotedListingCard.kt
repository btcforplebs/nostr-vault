package com.nostrvault.ui.screens.feed

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.MarketListing
import com.nostrvault.ui.theme.BorderStrong
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.TertiaryGroupedBg

/**
 * A listing quoted in a note: photo, "Listing" or "Auction", title and
 * price. Tapping opens the same sheet as the Marketplace grid, with Message
 * seller and Event Info. iOS `MarketplaceListingEmbedView`.
 */
@Composable
internal fun QuotedListingCard(listing: MarketListing, seller: FeedProfile?, modifier: Modifier = Modifier) {
    val colors = LocalNostrVaultColors.current
    var showSheet by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(8.dp)
    Row(
        verticalAlignment = Alignment.Top,
        modifier = modifier
            .fillMaxWidth()
            .clip(shape)
            .background(TertiaryGroupedBg)
            .border(1.dp, BorderStrong, shape)
            .clickable { showSheet = true }
            .padding(10.dp),
    ) {
        val thumb = Modifier.size(64.dp).clip(RoundedCornerShape(6.dp))
        if (listing.coverImage != null) {
            AsyncImage(
                model = listing.coverImage,
                contentDescription = listing.title,
                contentScale = ContentScale.Crop,
                modifier = thumb,
            )
        } else {
            MarketplaceImagePlaceholder(thumb)
        }
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(
                if (listing.isAuction) "Auction" else "Listing",
                color = colors.primary.copy(alpha = 0.8f),
                fontSize = 10.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                listing.title,
                color = PrimaryText.copy(alpha = 0.9f),
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Text(listing.priceLabel, color = colors.primary, fontSize = 13.sp, fontWeight = FontWeight.ExtraBold, maxLines = 1)
        }
    }
    if (showSheet) {
        MarketListingSheet(
            listing = listing,
            seller = seller,
            onOpenSeller = null,
            onDismiss = { showSheet = false },
        )
    }
}
