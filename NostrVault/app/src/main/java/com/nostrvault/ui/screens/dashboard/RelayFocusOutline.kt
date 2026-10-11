package com.nostrvault.ui.screens.dashboard

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.unit.dp
import com.nostrvault.data.model.*
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.*

/**
 * Outlines the row a notification tap landed on, in the card's own shape, and
 * fades it out when cleared. Port of iOS `relayFocusOutline`.
 */
internal fun Modifier.relayFocusOutline(isFocused: Boolean): Modifier = composed {
    val colors = LocalNostrVaultColors.current
    val alpha by animateFloatAsState(
        targetValue = if (isFocused) 1f else 0f,
        animationSpec = tween(durationMillis = if (isFocused) 200 else 600),
        label = "relayFocusOutline",
    )
    if (alpha == 0f) {
        Modifier
    } else {
        Modifier.border(
            width = 2.dp,
            color = colors.primary.copy(alpha = alpha),
            shape = RoundedCornerShape(12.dp),
        )
    }
}
