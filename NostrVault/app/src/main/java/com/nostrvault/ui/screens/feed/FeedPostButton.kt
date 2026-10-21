package com.nostrvault.ui.screens.feed

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedMode
import com.nostrvault.ui.components.blockedWhen
import com.nostrvault.ui.components.chromeFab
import com.nostrvault.ui.components.rememberChromeFolded
import com.nostrvault.ui.navigation.FloatingButtonRow.floatingRowButton
import com.nostrvault.ui.theme.*

/** The feed's floating Post button (iOS FeedView's compose capsule). It writes what the feed shows: [modeComposer]. */
@Composable
internal fun FeedPostButton(
    feedMode: FeedMode,
    modeComposer: com.nostrvault.ui.screens.ModeComposerKind?,
    meterLift: Dp,
    onPost: () -> Unit,
) {
    // Reading the flag inside this slot keeps recomposition scoped to the
    // FAB — the feed list never re-renders when it shows/hides.
    // The FAB folds with the bars, following the finger.
    val folded by rememberChromeFolded()
    // Reels has its own reply button, and the rail sits where the FAB would.
    if (feedMode != FeedMode.REELS) Box(Modifier.chromeFab().blockedWhen(folded).padding(bottom = meterLift)) {
        // iOS-style gradient "Post" capsule (FeedView compose FAB)
        val colors = LocalNostrVaultColors.current
        Surface(
            onClick = onPost,
            shape = RoundedCornerShape(50),
            color = Color.Transparent,
            modifier = Modifier
                .floatingRowButton()
                .shadow(
                    elevation = 8.dp,
                    shape = RoundedCornerShape(50),
                    ambientColor = colors.primary.copy(alpha = 0.35f),
                    spotColor = colors.primary.copy(alpha = 0.35f),
                ),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                modifier = Modifier
                    .background(
                        Brush.linearGradient(
                            listOf(colors.primary, colors.primaryLight),
                        ),
                        RoundedCornerShape(50),
                    )
                    .height(48.dp)
                    .padding(horizontal = 18.dp),
            ) {
                Icon(
                    when (modeComposer) {
                        com.nostrvault.ui.screens.ModeComposerKind.ARTICLE -> NostrVaultIcons.Articles
                        com.nostrvault.ui.screens.ModeComposerKind.RECIPE -> NostrVaultIcons.Recipes
                        com.nostrvault.ui.screens.ModeComposerKind.LISTING -> NostrVaultIcons.Marketplace
                        else -> NostrVaultIcons.Compose
                    },
                    contentDescription = "Compose",
                    tint = Color.White,
                    modifier = Modifier.size(18.dp),
                )
                Text(
                    text = modeComposer?.buttonTitle ?: "Post",
                    color = Color.White,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Bold,
                )
            }
        }
    }
}
