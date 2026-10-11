package com.nostrvault.ui.screens.dashboard

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.selected
import androidx.compose.foundation.layout.offset
import androidx.compose.ui.unit.dp
import com.nostrvault.data.model.*
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.*

// ═══════════════════════════════════════════════════════════════════
// IconFilterButton composable
// ═══════════════════════════════════════════════════════════════════

/**
 * Icon toggle for the Relay tab's pills; the note under the bar says what a
 * tap picked. [showDot] puts a red dot on its corner.
 */
@Composable
internal fun IconFilterButton(
    icon: ImageVector,
    contentDescription: String,
    isSelected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    showDot: Boolean = false,
) {
    val colors = LocalNostrVaultColors.current
    val tint by animateColorAsState(
        targetValue = if (isSelected) colors.primary else SecondaryText,
        animationSpec = Motion.control(),
        label = "filterTint",
    )
    Box(modifier = modifier.defaultMinSize(minWidth = 36.dp, minHeight = 36.dp)) {
        IconButton(
            onClick = onClick,
            // Bare icons: TalkBack hears which one is on.
            modifier = Modifier.size(36.dp).align(Alignment.Center).semantics { selected = isSelected },
        ) {
            Icon(
                imageVector = icon,
                contentDescription = contentDescription,
                tint = tint,
                modifier = Modifier.size(20.dp),
            )
        }
        AnimatedVisibility(
            visible = showDot,
            enter = scaleIn() + fadeIn(),
            exit = scaleOut() + fadeOut(),
            modifier = Modifier
                .align(Alignment.TopEnd)
                .offset(x = (-5).dp, y = 6.dp),
        ) {
            Box(Modifier.size(8.dp).background(ErrorRed, CircleShape))
        }
    }
}
