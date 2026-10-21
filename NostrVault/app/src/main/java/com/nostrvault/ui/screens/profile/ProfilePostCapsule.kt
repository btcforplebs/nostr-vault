package com.nostrvault.ui.screens.profile

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.components.blockedWhen
import com.nostrvault.ui.components.chromeFab
import com.nostrvault.ui.components.rememberChromeFolded
import com.nostrvault.ui.navigation.FloatingButtonRow.floatingRowButton
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.Motion
import com.nostrvault.ui.theme.NostrVaultIcons

/**
 * The Profile tab's floating "Post" capsule, which opens the note composer.
 * Port of iOS `MyProfileView.postButton` (MyProfileView.swift): the same
 * gradient capsule as the feed's, in the row above the tab bar it shares
 * with the mini player, folding away with the bars as the page scrolls,
 * and settling in a little while pressed (iOS PressScaleButtonStyle).
 */
@Composable
internal fun ProfilePostCapsule(onPost: () -> Unit) {
    val folded by rememberChromeFolded()
    val colors = LocalNostrVaultColors.current
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    // iOS: 0.94 scale (none under Reduce Motion) and slightly darker while held.
    val scale by animateFloatAsState(
        if (pressed && !Motion.isReduced) 0.94f else 1f,
        if (pressed) Motion.control() else Motion.pop(),
        label = "postPress",
    )
    Box(Modifier.chromeFab().blockedWhen(folded)) {
        Surface(
            onClick = onPost,
            shape = RoundedCornerShape(50),
            color = Color.Transparent,
            interactionSource = interaction,
            modifier = Modifier
                .floatingRowButton()
                .graphicsLayer { scaleX = scale; scaleY = scale }
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
                    .background(Brush.linearGradient(listOf(colors.primary, colors.primaryLight)), RoundedCornerShape(50))
                    .background(Color.Black.copy(alpha = if (pressed) 0.08f else 0f), RoundedCornerShape(50))
                    .height(48.dp)
                    .padding(horizontal = 18.dp),
            ) {
                Icon(NostrVaultIcons.Compose, contentDescription = null, tint = Color.White, modifier = Modifier.size(18.dp))
                Text("Post", color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.Bold)
            }
        }
    }
}
