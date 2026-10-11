package com.nostrvault.ui.screens

import androidx.compose.animation.*
import androidx.compose.ui.draw.alpha
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
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
import com.nostrvault.ui.theme.*

// ── Wizard colors (from iOS WizardColors) ────────────────────────

internal val WizardBgPrimary = Color(0xFF09090B)
internal val WizardBgCard = Color(0xFF18181B)
internal val WizardBgElevated = Color(0xFF27272A)
internal val WizardBorderSubtle = Color.White.copy(alpha = 0.06f)
internal val WizardBorderActive = Color(0xFFF59E0B).copy(alpha = 0.4f)
internal val WizardAccent = Color(0xFFF59E0B)
internal val WizardGradient = Brush.horizontalGradient(
    colors = listOf(Color(0xFFEA580C), Color(0xFFF59E0B)),
)

// ══════════════════════════════════════════════════════════════════
// Reusable wizard components
// ══════════════════════════════════════════════════════════════════

@Composable
internal fun WizardCard(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(WizardBgCard)
            .border(1.dp, WizardBorderSubtle, RoundedCornerShape(16.dp))
            .padding(24.dp),
        content = content,
    )
}

@Composable
internal fun WizardOptionCard(
    title: String,
    subtitle: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = modifier
            .clip(RoundedCornerShape(12.dp))
            .background(if (selected) WizardBgElevated else WizardBgCard)
            .border(
                width = if (selected) 2.dp else 1.dp,
                color = if (selected) WizardBorderActive else WizardBorderSubtle,
                shape = RoundedCornerShape(12.dp),
            )
            .clickable(onClick = onClick)
            .padding(16.dp),
    ) {
        Text(
            text = title,
            color = if (selected) WizardAccent else PrimaryText,
            fontSize = 15.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(4.dp))
        Text(
            text = subtitle,
            color = SecondaryText,
            fontSize = 12.sp,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
internal fun WizardPrimaryButton(
    text: String,
    enabled: Boolean = true,
    isLoading: Boolean = false,
    onClick: () -> Unit,
) {
    Button(
        onClick = onClick,
        enabled = enabled && !isLoading,
        shape = RoundedCornerShape(12.dp),
        colors = ButtonDefaults.buttonColors(
            containerColor = Color.Transparent,
            disabledContainerColor = Color.Transparent,
        ),
        contentPadding = PaddingValues(),
        modifier = Modifier
            .fillMaxWidth()
            .height(52.dp),
    ) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .fillMaxSize()
                .background(
                    brush = if (enabled) WizardGradient
                    else Brush.horizontalGradient(
                        listOf(Color(0xFF52525B), Color(0xFF52525B)),
                    ),
                    shape = RoundedCornerShape(12.dp),
                ),
        ) {
            if (isLoading) {
                CircularProgressIndicator(
                    color = Color.White,
                    strokeWidth = 2.dp,
                    modifier = Modifier.size(22.dp),
                )
            } else {
                Text(
                    text = text,
                    color = Color.White,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            }
        }
    }
}

@Composable
internal fun WizardSecondaryButton(
    text: String,
    onClick: () -> Unit,
) {
    TextButton(
        onClick = onClick,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Text(
            text = text,
            color = SecondaryText,
            fontSize = 15.sp,
        )
    }
}

@Composable
internal fun WizardTabRow(
    tabs: List<String>,
    selectedTab: Int,
    onTabSelected: (Int) -> Unit,
) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        for ((index, tab) in tabs.withIndex()) {
            val isSelected = index == selectedTab
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(8.dp))
                    .background(if (isSelected) WizardBgElevated else Color.Transparent)
                    .border(
                        width = 1.dp,
                        color = if (isSelected) WizardBorderActive else WizardBorderSubtle,
                        shape = RoundedCornerShape(8.dp),
                    )
                    .clickable { onTabSelected(index) }
                    .padding(vertical = 10.dp),
            ) {
                Text(
                    text = tab,
                    color = if (isSelected) WizardAccent else SecondaryText,
                    fontSize = 14.sp,
                    fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal,
                )
            }
        }
    }
}

// ══════════════════════════════════════════════════════════════════
// Step: Profile (New to Nostr)
// ══════════════════════════════════════════════════════════════════

@Composable
internal fun wizardTextFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedBorderColor = WizardAccent,
    unfocusedBorderColor = WizardBorderSubtle,
    cursorColor = WizardAccent,
    focusedLabelColor = WizardAccent,
)
