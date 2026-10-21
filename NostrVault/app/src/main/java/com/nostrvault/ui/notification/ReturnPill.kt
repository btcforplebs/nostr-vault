package com.nostrvault.ui.notification

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.nostrvault.service.ReturnPillManager
import com.nostrvault.ui.navigation.FloatingButtonRow
import com.nostrvault.ui.theme.NostrVaultIcons

/**
 * What came in while the app was away, as one pill at the bottom (iOS
 * `ReturnPill`): "5 mentions · 2 zaps · 1 DM", with an arrow down at the Vault
 * tab, the last one on the bar. Above the Post row, so it covers nothing. A tap
 * opens the Vault on its "Vault" list. [ReturnPillManager] decides when it shows.
 */
@Composable
fun ReturnPill(modifier: Modifier = Modifier) {
    val showing by ReturnPillManager.isShowing.collectAsState()
    val text by ReturnPillManager.text.collectAsState()
    val spoken by ReturnPillManager.spoken.collectAsState()
    AnimatedVisibility(
        visible = showing && text.isNotEmpty(),
        enter = slideInVertically { it } + fadeIn(),
        exit = slideOutVertically { it } + fadeOut(),
        modifier = modifier.padding(
            end = 12.dp,
            bottom = FloatingButtonRow.rowBottom + FloatingButtonRow.buttonHeight + 10.dp,
        ),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(PillStyle.innerGap),
            modifier = Modifier
                .pillCapsule(PillTone.ACCENT, onClick = ReturnPillManager::open)
                .semantics {
                    role = Role.Button
                    contentDescription = "While you were away: $spoken. Opens the Vault."
                },
        ) {
            PillIcon(NostrVaultIcons.Notifications)
            PillText(text)
            PillIcon(Icons.Filled.ArrowDownward)
        }
    }
}
