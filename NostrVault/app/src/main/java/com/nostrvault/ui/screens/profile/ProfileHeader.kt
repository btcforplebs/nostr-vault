package com.nostrvault.ui.screens.profile

import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
    /** Still waiting for the kind 0; held by the screen so scrolling does not restart the wait. */
    awaiting: Boolean,
) {
    val colors = LocalNostrVaultColors.current

    Column {
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
                    .padding(3.dp)
                    // iOS: a faint accent outline on the picture itself.
                    .border(1.5.dp, colors.primary.copy(alpha = 0.35f), CircleShape),
            )

            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = profile?.bestName ?: ProfileHeaderStyle.shortPubkey(pubkey),
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
                            tint = ProfileHeaderStyle.Verified,
                            modifier = Modifier.size(13.dp),
                        )
                    }
                    Spacer(Modifier.weight(1f))
                    StatusBadge(isOwnProfile, isFollowing, followsMe)
                }

                val nip05 = profile?.nip05?.takeIf { it.isNotBlank() }
                if (nip05 != null) {
                    Text(text = nip05, color = SecondaryText, fontSize = 12.sp, maxLines = 1)
                } else if (awaiting) {
                    Nip05Placeholder()
                }
            }
        }
        // The bio is the next item on the page; until the kind 0 says whether
        // there is one, keep its space here.
        if (awaiting) BioPlaceholder()
    }
}

@Composable
private fun StatusBadge(isOwnProfile: Boolean, isFollowing: Boolean, followsMe: Boolean) {
    val colors = LocalNostrVaultColors.current
    when {
        isOwnProfile -> Badge("YOU", colors.primary)
        isFollowing && followsMe -> MutualBadge()
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
        letterSpacing = 0.8.sp,
        modifier = Modifier
            .clip(RoundedCornerShape(4.dp))
            .background(color.copy(alpha = 0.15f))
            .padding(horizontal = 6.dp, vertical = 3.dp),
    )
}

/** iOS: a 13pt "∞" beside a 9pt "MUTUAL", in the verified green. */
@Composable
private fun MutualBadge() {
    val color = ProfileHeaderStyle.Verified
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(3.dp),
        modifier = Modifier
            .clip(RoundedCornerShape(4.dp))
            .background(color.copy(alpha = 0.13f))
            .padding(horizontal = 6.dp, vertical = 3.dp),
    ) {
        Text("∞", color = color, fontSize = 13.sp, fontWeight = FontWeight.Black, lineHeight = 13.sp)
        Text("MUTUAL", color = color, fontSize = 9.sp, fontWeight = FontWeight.Black, letterSpacing = 0.8.sp)
    }
}

internal object ProfileHeaderStyle {
    /** iOS `havenVerified` (0.2, 0.8, 0.6): the NIP-05 seal and the MUTUAL badge. */
    val Verified = Color(0xFF33CC99)

    /** iOS `ProfileFormat.shortPubkey`: first 8, "…", last 4. */
    fun shortPubkey(pubkey: String): String = pubkey.take(8) + "…" + pubkey.takeLast(4)
}
