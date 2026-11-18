package com.nostrvault.ui.screens.dm

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.service.DMSendState
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.LocalNostrVaultColors

/**
 * Under your own bubble while it is not yet out: "Sending…", or "Not sent"
 * with why and Try again / Remove (web net/dms.js; Messages check A2).
 */
@Composable
internal fun DMSendFooter(
    state: DMSendState,
    failure: String?,
    onRetry: (() -> Unit)?,
    onRemove: () -> Unit,
) {
    when (state) {
        DMSendState.SENDING -> Text(
            text = "Sending…",
            color = SecondaryText.copy(alpha = 0.7f),
            fontSize = 11.sp,
        )
        DMSendState.FAILED -> Column(horizontalAlignment = Alignment.End) {
            Text(
                text = listOfNotNull("Not sent", failure).joinToString(" · "),
                color = ErrorRed,
                fontSize = 11.sp,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp), modifier = Modifier.padding(top = 2.dp)) {
                val accent = LocalNostrVaultColors.current.primary
                if (onRetry != null) {
                    Text(
                        text = "Try again",
                        color = accent,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.clickable(onClick = onRetry).padding(vertical = 4.dp),
                    )
                }
                Text(
                    text = "Remove",
                    color = SecondaryText,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.clickable(onClick = onRemove).padding(vertical = 4.dp),
                )
            }
        }
    }
}
