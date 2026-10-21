package com.nostrvault.ui.screens.dashboard

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText

/**
 * What a Vault list's spinner says while the relay is starting: the relay's
 * own boot line when it has one, else "Starting relay...". Null when it is
 * not booting, so the list's own "Loading…" shows. iOS
 * `relayManager.isBooting` / `bootStatusMessage`.
 */
internal fun relayBootText(status: RelayForegroundService.RelayStatus, bootStatus: String): String? =
    if (status != RelayForegroundService.RelayStatus.BOOTING) null
    else bootText(bootStatus)

/** The boot line, or "Starting relay..." before the relay has said anything. */
internal fun bootText(bootStatus: String): String = bootStatus.ifBlank { "Starting relay..." }

/**
 * A Vault list still loading: a spinner, [title], and "This may take a
 * moment" in small mono. iOS VaultModeLists' loading views.
 */
@Composable
internal fun VaultLoadingState(title: String, topPadding: Dp, showHint: Boolean = true) {
    val colors = LocalNostrVaultColors.current
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
        modifier = Modifier.fillMaxSize().padding(top = topPadding),
    ) {
        CircularProgressIndicator(color = colors.primary, modifier = Modifier.size(32.dp))
        Spacer(Modifier.height(16.dp))
        Text(title, color = PrimaryText, fontSize = 18.sp, fontWeight = FontWeight.Bold, letterSpacing = 0.3.sp)
        if (showHint) {
            Spacer(Modifier.height(8.dp))
            Text(
                "This may take a moment",
                color = SecondaryText.copy(alpha = SecondaryText.alpha * 0.6f),
                fontSize = 12.sp,
                fontWeight = FontWeight.Medium,
                fontFamily = FontFamily.Monospace,
                letterSpacing = 0.5.sp,
            )
        }
    }
}

/**
 * An empty Vault list: a 48 thin icon in a two-colour gradient, an 18 bold
 * title and a 13 mono hint. [extra] goes under the hint (Articles' "Load
 * older"). iOS VaultModeLists' empty views.
 */
@Composable
internal fun VaultEmptyState(
    icon: ImageVector,
    gradient: List<Color>,
    title: String,
    hint: String,
    topPadding: Dp,
    extra: @Composable ColumnScope.() -> Unit = {},
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
        modifier = Modifier.fillMaxSize().padding(top = topPadding),
    ) {
        GradientIcon(icon, gradient, 48.dp)
        Spacer(Modifier.height(24.dp))
        Text(title, color = PrimaryText, fontSize = 18.sp, fontWeight = FontWeight.Bold, letterSpacing = 0.2.sp)
        Spacer(Modifier.height(8.dp))
        Text(
            hint,
            color = SecondaryText,
            fontSize = 13.sp,
            fontFamily = FontFamily.Monospace,
            letterSpacing = 0.3.sp,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = 24.dp),
        )
        extra()
    }
}

/** The Vault accent's gradient (iOS havenPurple → havenPurpleLight). */
@Composable
internal fun vaultAccentGradient(): List<Color> {
    val colors = LocalNostrVaultColors.current
    return listOf(colors.primary, colors.primaryLight)
}

/** An icon filled top-left to bottom-right with [gradient] (iOS `foregroundStyle(LinearGradient)`). */
@Composable
internal fun GradientIcon(icon: ImageVector, gradient: List<Color>, size: Dp) {
    Icon(
        icon,
        contentDescription = null,
        tint = Color.White,
        modifier = Modifier
            .size(size)
            .graphicsLayer(compositingStrategy = CompositingStrategy.Offscreen)
            .drawWithCache {
                val brush = Brush.linearGradient(gradient, start = androidx.compose.ui.geometry.Offset.Zero,
                    end = androidx.compose.ui.geometry.Offset(this.size.width, this.size.height))
                onDrawWithContent {
                    drawContent()
                    drawRect(brush, blendMode = BlendMode.SrcAtop)
                }
            },
    )
}
