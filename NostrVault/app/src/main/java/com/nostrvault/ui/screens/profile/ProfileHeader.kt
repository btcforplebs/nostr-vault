package com.nostrvault.ui.screens.profile

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.layout
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.theme.*

@Composable
internal fun ProfileHeader(
    profile: com.nostrvault.data.model.FeedProfile?,
    pubkey: String,
    isOwnProfile: Boolean,
    isFollowing: Boolean,
    followsMe: Boolean,
) {
    val colors = LocalNostrVaultColors.current

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 16.dp, end = 16.dp, top = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        AvatarImage(
            url = profile?.pictureURL,
            pubkey = profile?.pubkey ?: pubkey,
            size = 72.dp,
            displayName = profile?.bestName,
            modifier = Modifier
                // Half over the banner; the name column stays below it.
                .layout { measurable, constraints ->
                    val placeable = measurable.measure(constraints)
                    val overlap = ProfileBannerStyle.avatarOverlap.roundToPx()
                    layout(placeable.width, placeable.height - overlap) { placeable.place(0, -overlap) }
                }
                // A ring in the page color lifts the avatar off the banner.
                .background(WindowBackground, CircleShape)
                .padding(3.dp),
        )

        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = profile?.bestName ?: "${pubkey.take(8)}…",
                    color = PrimaryText,
                    fontSize = 20.sp,
                    fontWeight = FontWeight.Bold,
                    maxLines = 1,
                    overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                if (!profile?.nip05.isNullOrBlank()) {
                    Spacer(Modifier.width(6.dp))
                    Icon(
                        NostrVaultIcons.Verified,
                        contentDescription = null,
                        tint = colors.primary,
                        modifier = Modifier.size(14.dp),
                    )
                }
                Spacer(Modifier.weight(1f))
                StatusBadge(isOwnProfile, isFollowing, followsMe)
            }

            profile?.nip05?.takeIf { it.isNotBlank() }?.let {
                Text(text = it, color = SecondaryText, fontSize = 12.sp, maxLines = 1)
            }
        }
    }
}

@Composable
private fun StatusBadge(isOwnProfile: Boolean, isFollowing: Boolean, followsMe: Boolean) {
    val colors = LocalNostrVaultColors.current
    val mutualColor = Color(0xFF33E6B3)
    when {
        isOwnProfile -> Badge("YOU", colors.primary)
        isFollowing && followsMe -> Badge("∞ MUTUAL", mutualColor)
        isFollowing -> Badge("FOLLOWING", Color(0xFF4CAF50))
        followsMe -> Badge("FOLLOWS YOU", SecondaryText)
        else -> {}
    }
}

@Composable
private fun Badge(text: String, color: Color) {
    Text(
        text = text,
        color = color,
        fontSize = 9.sp,
        fontWeight = FontWeight.Black,
        modifier = Modifier
            .clip(RoundedCornerShape(4.dp))
            .background(color.copy(alpha = 0.15f))
            .padding(horizontal = 6.dp, vertical = 3.dp),
    )
}
