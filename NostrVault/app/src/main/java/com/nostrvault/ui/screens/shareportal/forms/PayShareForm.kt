package com.nostrvault.ui.screens.shareportal.forms

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.nostrvault.ui.theme.SecondaryText

/**
 * Pay or zap from the share sheet: what will be paid and nothing else. No
 * amount is set here and nothing is paid; the app's review card shows the
 * amount and asks first. Twin: PayShareForm.swift.
 */
@Composable
internal fun PayShareForm(
    target: String?,
    onBack: () -> Unit,
    onSend: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Pay or zap", style = MaterialTheme.typography.titleSmall)
        target?.let { Text(it, maxLines = 2, overflow = TextOverflow.Ellipsis, fontFamily = FontFamily.Monospace, color = SecondaryText) }
        Text("Nothing is paid from here. The app shows the amount and asks before your wallet sends anything.",
            color = SecondaryText, style = MaterialTheme.typography.bodySmall)
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(onClick = onSend, enabled = target != null) { Text("Send to Nostr Vault") }
            TextButton(onClick = onBack) { Text("Back") }
        }
    }
}
