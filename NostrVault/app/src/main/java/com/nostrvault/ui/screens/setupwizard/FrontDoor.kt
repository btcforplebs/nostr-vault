package com.nostrvault.ui.screens

import androidx.compose.animation.*
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.R
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.flow.first

// ══════════════════════════════════════════════════════════════════
// Step 1: Welcome (the front door)
// ══════════════════════════════════════════════════════════════════

/**
 * The first screen after install. It used to be a card and five feature
 * bullets with Get Started below the fold, then a separate choose-your-setup
 * screen whose Continue only enabled after picking a card. Now it fits one
 * phone screen and the three ways in are the buttons themselves. Same layout
 * numbers as the iOS front door.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun FrontDoor(onChoose: (SetupPath) -> Unit) {
    var showWhatsInside by remember { mutableStateOf(false) }
    var appeared by remember { mutableStateOf(Motion.isReduced) }
    LaunchedEffect(Unit) { appeared = true }
    val heroAlpha by animateFloatAsState(
        targetValue = if (appeared) 1f else 0f,
        animationSpec = tween(if (Motion.isReduced) 0 else 450),
        label = "front_door_hero",
    )

    BoxWithConstraints(
        modifier = Modifier
            .fillMaxSize()
            .statusBarsPadding()
            .navigationBarsPadding()
            .padding(horizontal = 24.dp),
    ) {
        // Tall phones get a bigger icon so the block fills the space instead
        // of floating; small phones are already tight.
        val iconSize = if (maxHeight > 800.dp) 112.dp else 92.dp

        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.fillMaxSize(),
        ) {
            // Centred in the space above the buttons. When it can't fit
            // (large font scale), only this part scrolls and the buttons stay
            // pinned.
            BoxWithConstraints(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth(),
            ) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                    modifier = Modifier
                        .fillMaxWidth()
                        .verticalScroll(rememberScrollState())
                        .heightIn(min = maxHeight)
                        .padding(vertical = 16.dp)
                        .alpha(heroAlpha),
                ) {
                    FrontDoorHero(iconSize = iconSize, onWhatsInside = { showWhatsInside = true })
                }
            }

            // No entrance delay: these are tappable on the first frame.
            Column(
                verticalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.padding(top = 16.dp, bottom = 16.dp),
            ) {
                WizardPrimaryButton(text = "Create an account", onClick = { onChoose(SetupPath.NEW_TO_NOSTR) })
                FrontDoorSecondaryButton(text = "I already use Nostr", onClick = { onChoose(SetupPath.USE_NOSTR) })
                // "Just look around" is Mac-only on iOS (WelcomeStepView), so a
                // phone offers just these two.
            }
        }
    }

    if (showWhatsInside) {
        ModalBottomSheet(
            onDismissRequest = { showWhatsInside = false },
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
            containerColor = WizardBgPrimary,
        ) {
            WhatsInsideSheet(onDone = { showWhatsInside = false })
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun FrontDoorHero(iconSize: Dp, onWhatsInside: () -> Unit) {
    // The icon they just tapped on the home screen, with the amber glow.
    Box(contentAlignment = Alignment.Center, modifier = Modifier.size(iconSize + 4.dp)) {
        Box(
            modifier = Modifier
                .requiredSize(iconSize * 1.6f)
                .background(
                    Brush.radialGradient(
                        listOf(WizardAccent.copy(alpha = 0.35f), Color.Transparent),
                    ),
                    CircleShape,
                ),
        )
        val corner = RoundedCornerShape(iconSize * 0.2237f)
        Image(
            painter = painterResource(R.drawable.vault_mark),
            contentDescription = null,
            modifier = Modifier
                .size(iconSize)
                .clip(corner)
                .border(1.dp, Color.White.copy(alpha = 0.08f), corner),
        )
    }

    Spacer(Modifier.height(24.dp))
    Text(
        text = "Nostr Vault",
        color = PrimaryText,
        fontSize = 34.sp,
        fontWeight = FontWeight.Bold,
        modifier = Modifier.semantics { heading() },
    )
    Spacer(Modifier.height(8.dp))
    // Broken by hand so it splits at the comma on every width.
    Text(
        text = "Your posts, messages and media,\nkept on your own device.",
        color = SecondaryText,
        fontSize = 17.sp,
        lineHeight = 22.sp,
        textAlign = TextAlign.Center,
    )

    Spacer(Modifier.height(24.dp))
    // Wraps rather than truncating at large font scale. Not buttons: they
    // describe, they don't do anything.
    FlowRow(
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier
            .fillMaxWidth()
            .clearAndSetSemantics { contentDescription = "Includes your own relay, private DMs and zaps" },
    ) {
        FrontDoorChip(NostrVaultIcons.AppIcon, "Own relay")
        FrontDoorChip(NostrVaultIcons.Lock, "Private DMs")
        FrontDoorChip(NostrVaultIcons.Zap, "Zaps")
    }

    Spacer(Modifier.height(12.dp))
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .heightIn(min = 32.dp)
            .clip(RoundedCornerShape(8.dp))
            .clickable(role = Role.Button, onClick = onWhatsInside)
            .padding(horizontal = 8.dp),
    ) {
        Text(
            text = "What's inside?",
            color = WizardAccent,
            fontSize = 13.sp,
            fontWeight = FontWeight.Medium,
        )
    }
}

@Composable
private fun FrontDoorChip(icon: ImageVector, label: String) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier
            .heightIn(min = 32.dp)
            .background(WizardBgCard, CircleShape)
            .border(1.dp, BorderStrong, CircleShape)
            .padding(horizontal = 12.dp),
    ) {
        Icon(icon, contentDescription = null, tint = WizardAccent, modifier = Modifier.size(14.dp))
        Text(label, color = PrimaryText, fontSize = 13.sp, fontWeight = FontWeight.Medium, maxLines = 1)
    }
}

@Composable
private fun FrontDoorSecondaryButton(text: String, onClick: () -> Unit) {
    val shape = RoundedCornerShape(12.dp)
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .fillMaxWidth()
            .height(52.dp)
            .clip(shape)
            .background(WizardBgCard, shape)
            .border(1.dp, BorderStrong, shape)
            .clickable(role = Role.Button, onClick = onClick),
    ) {
        Text(text = text, color = PrimaryText, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
    }
}
