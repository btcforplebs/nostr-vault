package com.nostrvault.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.nostrvault.data.model.*
import com.nostrvault.ui.components.*
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.flow.*
import java.util.*

// ── Thread connector line ───────────────────────────────────────

@Composable
internal fun ThreadConnectorLine(color: androidx.compose.ui.graphics.Color) {
    Box(
        modifier = Modifier
            .padding(start = ThreadSideInset + 36.dp)
            .width(1.5.dp)
            .height(12.dp)
            .background(color.copy(alpha = 0.25f)),
    )
}
