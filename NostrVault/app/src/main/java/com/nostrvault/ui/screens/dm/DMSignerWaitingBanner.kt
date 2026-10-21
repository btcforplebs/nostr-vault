package com.nostrvault.ui.screens.dm

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Key
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText

/** iOS DMInboxView signerWaitingBanner: what the signer hasn't opened, and a Retry. */
@Composable
internal fun DMSignerWaitingBanner(count: Int, onRetry: () -> Unit) {
    val orange = Color(0xFFFF9500) // iOS .orange
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .background(orange.copy(alpha = 0.12f))
            .padding(horizontal = 16.dp, vertical = 10.dp),
    ) {
        Icon(Icons.Filled.Key, contentDescription = null, tint = orange, modifier = Modifier.size(15.dp))
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text(DMSignerWaiting.text(count), color = PrimaryText, fontSize = 13.sp)
            // Android's own line: Retry asks Amber silently, so it only works
            // once auto-sign is on (iOS asks again through its normal path).
            Text(DMSignerWaiting.HINT, color = SecondaryText, fontSize = 12.sp)
        }
        Spacer(Modifier.width(8.dp))
        TextButton(onClick = onRetry) {
            Text("Retry", color = LocalNostrVaultColors.current.primary, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

internal object DMSignerWaiting {
    const val HINT = "Turn on auto-sign for Nostr Vault in Amber, then tap Retry."

    /** iOS wording, word for word. */
    fun text(count: Int): String =
        if (count == 1) "1 message is waiting for your signer to open it."
        else "$count messages are waiting for your signer to open them."
}
