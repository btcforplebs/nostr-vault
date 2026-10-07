package com.nostrvault.tutorials

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import kotlin.math.roundToInt

/**
 * Draws the active tutorial's card, pointing at its anchor (iOS
 * `TutorialStage`). It sits over the live app and never dims or blocks it:
 * only the card takes touches. Lives in MainActivity's root box, above the
 * nav host, so it stays over every screen.
 *
 * A card that points at something waits until that thing is on screen:
 * replayed from Settings, the feed is still coming back into view.
 */
@Composable
fun TutorialStage(account: () -> String, modifier: Modifier = Modifier) {
    val active by TutorialCenter.active.collectAsState()
    val stepIndex by TutorialCenter.stepIndex.collectAsState()
    val id = active ?: return
    val step = id.steps.getOrNull(stepIndex) ?: return
    val anchor = step.anchor?.let { TutorialCenter.anchors[it] }
    if (step.anchor != null && anchor == null) return

    val density = LocalDensity.current
    val primary = LocalNostrVaultColors.current.primary
    var rootOrigin by remember { mutableStateOf(Offset.Zero) }
    var cardHeight by remember { mutableStateOf(0) }

    BoxWithConstraints(
        modifier
            .fillMaxSize()
            .onGloballyPositioned { rootOrigin = it.positionInRoot() },
    ) {
        val widthPx = with(density) { maxWidth.toPx() }
        val heightPx = with(density) { maxHeight.toPx() }
        val marginPx = with(density) { 16.dp.toPx() }
        val cardWidth = minOf(340.dp, maxWidth - 32.dp)
        val cardWidthPx = with(density) { cardWidth.toPx() }
        val local = anchor?.translate(-rootOrigin)

        if (local != null) {
            val pad = with(density) { 6.dp.toPx() }
            Box(
                Modifier
                    .offset { IntOffset((local.left - pad).roundToInt(), (local.top - pad).roundToInt()) }
                    .size(
                        with(density) { (local.width + 2 * pad).toDp() },
                        with(density) { (local.height + 2 * pad).toDp() },
                    )
                    .border(3.dp, primary, RoundedCornerShape(50)),
            )
        }

        // Below the anchor when it's in the top half, above it otherwise,
        // kept on screen. With no anchor, low and centred.
        val x = if (local == null) (widthPx - cardWidthPx) / 2 else
            (local.center.x - cardWidthPx / 2).coerceIn(marginPx, widthPx - cardWidthPx - marginPx)
        val y = when {
            local == null -> heightPx - cardHeight - with(density) { 120.dp.toPx() }
            local.center.y < heightPx / 2 -> local.bottom + marginPx
            else -> local.top - marginPx - cardHeight
        }

        Box(
            Modifier
                .offset { IntOffset(x.roundToInt(), y.roundToInt()) }
                .width(cardWidth)
                .onSizeChanged { cardHeight = it.height },
        ) {
            AnimatedContent(
                targetState = stepIndex,
                transitionSpec = { fadeIn() togetherWith fadeOut() },
                label = "tutorialCard",
            ) { index ->
                val shown = id.steps.getOrNull(index) ?: return@AnimatedContent
                TutorialCard(
                    position = "${index + 1} of ${id.steps.size}",
                    step = shown,
                    canGoBack = index > 0,
                    isLast = index >= id.steps.size - 1,
                    onSkip = { TutorialCenter.skip(id, account()) },
                    onBack = { TutorialCenter.back() },
                    onNext = { TutorialCenter.next(account()) },
                )
            }
        }
    }
}

@Composable
private fun TutorialCard(
    position: String,
    step: TutorialStep,
    canGoBack: Boolean,
    isLast: Boolean,
    onSkip: () -> Unit,
    onBack: () -> Unit,
    onNext: () -> Unit,
) {
    val primary = LocalNostrVaultColors.current.primary
    val shape = RoundedCornerShape(18.dp)
    Column(
        Modifier
            .fillMaxWidth()
            .shadow(16.dp, shape)
            .background(Color(0xFF1F1F1F), shape)
            .border(1.dp, primary.copy(alpha = 0.6f), shape)
            .padding(16.dp)
            .semantics { paneTitle = "Tutorial" },
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(position, color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.weight(1f))
            TextButton(onClick = onSkip) {
                Text("Skip", color = SecondaryText, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            }
        }
        Text(step.title, color = PrimaryText, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(6.dp))
        Text(step.body, color = PrimaryText.copy(alpha = 0.85f), fontSize = 15.sp)
        Spacer(Modifier.height(10.dp))
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
            if (canGoBack) {
                TextButton(onClick = onBack) { Text("Back", color = PrimaryText.copy(alpha = 0.85f)) }
            }
            Spacer(Modifier.weight(1f))
            Button(
                onClick = onNext,
                colors = ButtonDefaults.buttonColors(containerColor = primary, contentColor = Color.White),
            ) {
                Text(if (isLast) "Done" else "Next", fontWeight = FontWeight.SemiBold)
            }
        }
    }
}
