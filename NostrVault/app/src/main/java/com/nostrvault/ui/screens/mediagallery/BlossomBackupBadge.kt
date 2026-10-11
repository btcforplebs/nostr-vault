package com.nostrvault.ui.screens

import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.service.*
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

/** One tile's Blossom backup answer and the actions on it. */
@Stable
internal class BackupBadgeState(
    /** Null until every configured server has answered once. */
    val summary: BlossomBackupSummary?,
    val mirrorCount: Int,
    /** The server list, so adding one asks again instead of leaving the count unknown. */
    val mirrorsKey: List<String>,
    val busy: Boolean,
    val check: suspend () -> Unit,
    val onMirror: () -> Unit,
    val onSaveToVault: () -> Unit,
)

/**
 * The cloud "x/y" badge: green on every server, orange on some, grey on none,
 * "?" when a server could not be asked. Port of iOS `BlossomBackupBadge`.
 */
@Composable
internal fun BlossomBackupBadge(
    backup: BackupBadgeState,
    modifier: Modifier = Modifier,
    compact: Boolean = false,
) {
    val summary = backup.summary
    // Re-runs after a pull to refresh clears the answers (summary goes null).
    LaunchedEffect(backup.mirrorsKey, summary == null) {
        if (summary == null) backup.check()
    }
    val tint = when {
        summary == null || summary.present == 0 -> SecondaryText
        summary.isComplete -> Color(0xFF4CAF50)
        else -> Color(0xFFFF9800)
    }
    val total = backup.mirrorCount
    val text = when {
        summary == null -> "–/$total"
        summary.unreachable > 0 && summary.present < summary.total -> "${summary.present}/$total?"
        else -> "${summary.present}/$total"
    }
    val label = when {
        summary == null -> "Checking your Blossom servers"
        summary.unreachable > 0 -> "On ${summary.present} of $total Blossom servers, ${summary.unreachable} could not be reached"
        else -> "On ${summary.present} of $total Blossom servers"
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier.semantics(mergeDescendants = true) { contentDescription = label },
    ) {
        Icon(
            imageVector = if (summary?.isComplete == true) NostrVaultIcons.CloudDone else NostrVaultIcons.Cloud,
            contentDescription = null,
            tint = tint,
            modifier = Modifier.size(if (compact) 10.dp else 13.dp),
        )
        Spacer(Modifier.width(3.dp))
        Text(
            text = text,
            color = tint,
            fontSize = if (compact) 10.sp else 12.sp,
            fontWeight = FontWeight.SemiBold,
            style = androidx.compose.ui.text.TextStyle(fontFeatureSettings = "tnum"),
        )
    }
}
