package com.nostrvault.ui.navigation

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.components.glassPillBackground
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.LocalOledMode
import com.nostrvault.ui.theme.Motion
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.SecondaryGroupedBg
import com.nostrvault.ui.theme.ZapOrange

/**
 * Floating pill-shaped bottom navigation bar matching the iOS tab structure.
 * Tab order: Feed | Search | Profile (center, avatar) | Media | Relay
 *
 * Profile tab shows user avatar with a colored ring and supports
 * long-press to trigger account switching.
 */

/**
 * How much of the screen's bottom edge the floating nav bar covers, including
 * the system navigation inset under it; zero while the bar is hidden.
 *
 * The bar is laid over the tab content rather than beside it, so its height
 * never reaches a screen's insets or Scaffold padding. Lists get away with a
 * fixed bottom content padding; a full-bleed screen whose controls sit at the
 * bottom edge (Reels) needs the real number. Measured by [NostrVaultNavHost].
 * Mirrors iOS `floatingTabBarHeight`.
 */
object FloatingNavBarInset {
    val height: MutableState<Dp> = mutableStateOf(0.dp)
}

data class BottomNavItem(
    val screen: Screen,
    val label: String,
    val icon: ImageVector,
)

val bottomNavItems = listOf(
    BottomNavItem(Screen.Feed, "Feed", NostrVaultIcons.Feed),
    BottomNavItem(Screen.Search, "Search", NostrVaultIcons.Search),
    BottomNavItem(Screen.Profile, "Profile", NostrVaultIcons.Profile), // center
    BottomNavItem(Screen.MediaGallery, "Media", NostrVaultIcons.Media),
    BottomNavItem(Screen.Dashboard, "Relay", NostrVaultIcons.Relay),
)

@Composable
fun BottomNavBar(
    currentRoute: String?,
    activeAccountPubkey: String,
    activeAvatarUrl: String? = null,
    activeDisplayName: String? = null,
    isOwner: Boolean,
    condensed: Boolean = false,
    hasUnreadDMs: Boolean = false,
    hasNewRelayActivity: Boolean = false,
    onNavigate: (Screen) -> Unit,
    onReselect: (Screen) -> Unit = {},
    onAccountSwitcher: () -> Unit,
    condensedActionIcon: ImageVector = NostrVaultIcons.Create,
    condensedActionTint: Color? = null,
    onCondensedAction: () -> Unit = {},
    onExpand: () -> Unit = {},
) {
    val colors = LocalNostrVaultColors.current
    val isOled = LocalOledMode.current

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .navigationBarsPadding()
            .padding(horizontal = 24.dp, vertical = 12.dp),
        contentAlignment = Alignment.Center,
    ) {
        // Morph between the full 5-tab row and a condensed avatar + compose
        // cluster. SizeTransform shrinks the glass pill inward from both sides;
        // the cross-fade + scale mirrors the iOS distillation. This is
        // scroll-driven chrome, so it takes the `chrome` token — damping 0.86
        // rather than the 0.82 it had, because a bar that overshoots after your
        // thumb has already stopped reads as a bug.
        AnimatedContent(
            targetState = condensed,
            transitionSpec = {
                val barSpring = Motion.chrome<Float>()
                (fadeIn(barSpring) + scaleIn(barSpring, initialScale = 0.9f)) togetherWith
                    (fadeOut(barSpring) + scaleOut(barSpring, targetScale = 0.9f)) using
                    SizeTransform(clip = false) { _, _ -> Motion.chrome() }
            },
            label = "navBarCondense",
        ) { isCondensed ->
            if (isCondensed) {
                CondensedNavCluster(
                    isOwner = isOwner,
                    activeAccountPubkey = activeAccountPubkey,
                    activeAvatarUrl = activeAvatarUrl,
                    activeDisplayName = activeDisplayName,
                    showBadge = hasUnreadDMs || hasNewRelayActivity,
                    primaryColor = colors.primary,
                    isOled = isOled,
                    actionIcon = condensedActionIcon,
                    actionTint = condensedActionTint ?: colors.primary,
                    onAction = onCondensedAction,
                    onExpand = onExpand,
                    onAccountSwitcher = onAccountSwitcher,
                )
            } else {
                ExpandedNavRow(
                    currentRoute = currentRoute,
                    primaryColor = colors.primary,
                    isOled = isOled,
                    isOwner = isOwner,
                    activeAccountPubkey = activeAccountPubkey,
                    activeAvatarUrl = activeAvatarUrl,
                    activeDisplayName = activeDisplayName,
                    hasUnreadDMs = hasUnreadDMs,
                    hasNewRelayActivity = hasNewRelayActivity,
                    onNavigate = onNavigate,
                    onReselect = onReselect,
                    onAccountSwitcher = onAccountSwitcher,
                )
            }
        }
    }
}

@Composable
private fun ExpandedNavRow(
    currentRoute: String?,
    primaryColor: Color,
    isOled: Boolean,
    isOwner: Boolean,
    activeAccountPubkey: String,
    activeAvatarUrl: String?,
    activeDisplayName: String?,
    hasUnreadDMs: Boolean,
    hasNewRelayActivity: Boolean,
    onNavigate: (Screen) -> Unit,
    onReselect: (Screen) -> Unit,
    onAccountSwitcher: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .glassPillBackground(isOled = isOled, accentColor = primaryColor)
            .padding(horizontal = 8.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.SpaceEvenly,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        for (item in bottomNavItems) {
            val isProfileTab = item.screen == Screen.Profile
            val selected = if (isProfileTab) {
                currentRoute?.startsWith("profile") == true
            } else {
                currentRoute == item.screen.route
            }

            if (isProfileTab) {
                ProfileTab(
                    selected = selected,
                    selectedColor = primaryColor,
                    isOwner = isOwner,
                    activeAccountPubkey = activeAccountPubkey,
                    activeAvatarUrl = activeAvatarUrl,
                    activeDisplayName = activeDisplayName,
                    showBadge = hasUnreadDMs,
                    onClick = {
                        if (selected) {
                            onReselect(Screen.Profile)
                        } else {
                            onNavigate(Screen.Profile)
                        }
                    },
                    onLongClick = onAccountSwitcher,
                    modifier = Modifier.weight(1f),
                )
            } else {
                NavTab(
                    icon = item.icon,
                    label = item.label,
                    selected = selected,
                    selectedColor = primaryColor,
                    showBadge = item.screen == Screen.Dashboard && hasNewRelayActivity,
                    onClick = {
                        if (selected) {
                            onReselect(item.screen)
                        } else {
                            onNavigate(item.screen)
                        }
                    },
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

/**
 * Collapsed form of the nav bar shown while scrolling the feed: the bar
 * distills to "who am I" (avatar — tap to expand, long-press to switch
 * accounts) plus the single most likely action (compose). Mirrors iOS's
 * collapsedContent.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun CondensedNavCluster(
    isOwner: Boolean,
    activeAccountPubkey: String,
    activeAvatarUrl: String?,
    activeDisplayName: String?,
    showBadge: Boolean,
    primaryColor: Color,
    isOled: Boolean,
    actionIcon: ImageVector,
    actionTint: Color,
    onAction: () -> Unit,
    onExpand: () -> Unit,
    onAccountSwitcher: () -> Unit,
) {
    val haptic = LocalHapticFeedback.current
    val ringColor = if (isOwner) primaryColor else ZapOrange

    Row(
        modifier = Modifier
            .glassPillBackground(isOled = isOled, accentColor = primaryColor)
            .padding(horizontal = 14.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // Avatar — tap to expand the bar, long-press to switch accounts.
        Box(
            modifier = Modifier
                .clip(CircleShape)
                .combinedClickable(
                    onClick = onExpand,
                    onLongClick = {
                        haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                        onAccountSwitcher()
                    },
                ),
        ) {
            Box(
                modifier = Modifier
                    .size(36.dp)
                    .border(width = 1.5.dp, color = ringColor, shape = CircleShape)
                    .padding(2.dp)
                    .clip(CircleShape)
                    .background(SecondaryGroupedBg),
                contentAlignment = Alignment.Center,
            ) {
                AvatarImage(
                    url = activeAvatarUrl,
                    pubkey = activeAccountPubkey,
                    size = 28.dp,
                    displayName = activeDisplayName,
                )
            }
            if (showBadge) {
                Box(
                    modifier = Modifier
                        .size(10.dp)
                        .align(Alignment.TopEnd)
                        .offset(x = 2.dp, y = (-2).dp)
                        .background(ErrorRed, CircleShape),
                )
            }
        }

        // Contextual action — compose / Blossom upload / relay dashboard,
        // depending on the active tab (icon + tint supplied by the caller).
        Box(
            modifier = Modifier
                .size(36.dp)
                .clip(CircleShape)
                .background(actionTint.copy(alpha = 0.15f))
                .combinedClickableCompat(onClick = onAction),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = actionIcon,
                contentDescription = "Action",
                tint = actionTint,
                modifier = Modifier.size(20.dp),
            )
        }
    }
}

@Composable
private fun NavTab(
    icon: ImageVector,
    label: String,
    selected: Boolean,
    selectedColor: Color,
    showBadge: Boolean = false,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val scale by animateFloatAsState(
        targetValue = if (selected) 1.1f else 1.0f,
        animationSpec = Motion.control(),
        label = "tabScale",
    )

    Column(
        modifier = modifier
            .clip(CircleShape)
            .semantics { role = Role.Tab }
            .combinedClickableCompat(onClick = onClick)
            .padding(vertical = 6.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Box {
            Icon(
                imageVector = icon,
                contentDescription = label,
                tint = if (selected) selectedColor else Color.White,
                modifier = Modifier
                    .size(31.dp)
                    .scale(scale),
            )
            if (showBadge) {
                Box(
                    modifier = Modifier
                        .size(8.dp)
                        .align(Alignment.TopEnd)
                        .offset(x = 2.dp, y = (-2).dp)
                        .background(ErrorRed, CircleShape),
                )
            }
        }
        Text(
            text = label,
            fontSize = 10.sp,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            color = if (selected) selectedColor else Color.White,
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ProfileTab(
    selected: Boolean,
    selectedColor: Color,
    isOwner: Boolean,
    activeAccountPubkey: String,
    activeAvatarUrl: String?,
    activeDisplayName: String?,
    showBadge: Boolean = false,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val haptic = LocalHapticFeedback.current
    val scale by animateFloatAsState(
        targetValue = if (selected) 1.1f else 1.0f,
        animationSpec = Motion.control(),
        label = "profileScale",
    )
    val ringColor = if (isOwner) selectedColor else ZapOrange

    Column(
        modifier = modifier
            .clip(CircleShape)
            .semantics { role = Role.Tab }
            .combinedClickable(
                onClick = onClick,
                onLongClick = {
                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                    onLongClick()
                },
            )
            .padding(vertical = 6.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        // Avatar placeholder with ring
        Box {
            Box(
                modifier = Modifier
                    .size(31.dp)
                    .scale(scale)
                    .border(
                        width = if (selected) 1.5.dp else 0.dp,
                        color = if (selected) ringColor else Color.Transparent,
                        shape = CircleShape,
                    )
                    .padding(1.dp)
                    .clip(CircleShape)
                    .background(SecondaryGroupedBg),
                contentAlignment = Alignment.Center,
            ) {
                AvatarImage(
                    url = activeAvatarUrl,
                    pubkey = activeAccountPubkey,
                    size = 25.dp,
                    displayName = activeDisplayName,
                )
            }
            if (showBadge) {
                Box(
                    modifier = Modifier
                        .size(8.dp)
                        .align(Alignment.TopEnd)
                        .offset(x = 2.dp, y = (-2).dp)
                        .background(ErrorRed, CircleShape),
                )
            }
        }
        Text(
            text = "Profile",
            fontSize = 10.sp,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            color = if (selected) selectedColor else Color.White,
        )
    }
}

/**
 * Compatibility wrapper for combinedClickable that only uses onClick
 * (no long-press) — avoids the ExperimentalFoundationApi for non-profile tabs.
 */
@OptIn(ExperimentalFoundationApi::class)
private fun Modifier.combinedClickableCompat(
    onClick: () -> Unit,
): Modifier = this.combinedClickable(onClick = onClick)
