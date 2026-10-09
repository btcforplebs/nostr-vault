package com.nostrvault.ui.components

import androidx.compose.animation.*
import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Email
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.service.InAppBanner
import com.nostrvault.service.InAppBannerBus
import com.nostrvault.ui.navigation.DeepLinkRouter
import com.nostrvault.ui.navigation.PendingDeepLink
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

private const val BANNER_VISIBLE_MS = 4_000L
private val DmBlue = Color(0xFF0A84FF)

/**
 * Drop-down banner at the top of the app for a DM that arrives while the app
 * is open — the Android counterpart of iOS's RelayActivityBanner. Tap opens the
 * same place the system notification would; swipe up dismisses; it hides
 * itself after a few seconds.
 */
@Composable
fun InAppBannerHost(modifier: Modifier = Modifier) {
    val banner by InAppBannerBus.current.collectAsState()
    // Keep the last banner around so the exit animation still has content.
    var shown by remember { mutableStateOf<InAppBanner?>(null) }
    if (banner != null) shown = banner

    LaunchedEffect(banner?.id) {
        val id = banner?.id ?: return@LaunchedEffect
        delay(BANNER_VISIBLE_MS)
        InAppBannerBus.dismiss(id)
    }

    AnimatedVisibility(
        visible = banner != null,
        enter = slideInVertically(initialOffsetY = { -it }, animationSpec = Motion.bannerIn()) +
            fadeIn(Motion.bannerIn()),
        exit = slideOutVertically(targetOffsetY = { -it }, animationSpec = Motion.bannerOut()) +
            fadeOut(Motion.bannerOut()),
        modifier = modifier,
    ) {
        val current = shown ?: return@AnimatedVisibility
        val dragOffset = remember { Animatable(0f) }
        val scope = rememberCoroutineScope()
        val dismissThresholdPx = with(LocalDensity.current) { 24.dp.toPx() }

        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .padding(horizontal = 12.dp, vertical = 8.dp)
                .offset { IntOffset(0, dragOffset.value.coerceAtMost(0f).roundToInt()) }
                .draggable(
                    orientation = Orientation.Vertical,
                    state = rememberDraggableState { delta ->
                        scope.launch { dragOffset.snapTo(dragOffset.value + delta) }
                    },
                    onDragStopped = {
                        if (dragOffset.value < -dismissThresholdPx) InAppBannerBus.dismiss(current.id)
                        dragOffset.animateTo(0f, Motion.snapBack())
                    },
                )
                .clip(RoundedCornerShape(16.dp))
                .background(SecondaryGroupedBg)
                .clickable {
                    DeepLinkRouter.fromNotification(current.type, current.id, current.author, current.npub)
                        ?.let { PendingDeepLink.post(it) }
                    InAppBannerBus.dismiss(current.id)
                }
                .padding(horizontal = 14.dp, vertical = 12.dp),
        ) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier.size(34.dp).clip(CircleShape).background(DmBlue.copy(alpha = 0.18f)),
            ) {
                Icon(Icons.Filled.Email, contentDescription = null, tint = DmBlue, modifier = Modifier.size(18.dp))
            }
            Spacer(Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = current.title,
                    color = PrimaryText,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = current.text,
                    color = SecondaryText,
                    fontSize = 13.sp,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}
