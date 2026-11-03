package com.nostrvault.ui.screens.shareportal

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.nostrvault.service.UserStatusPublisher
import com.nostrvault.service.shareportal.handlers.StatusShareHandler
import com.nostrvault.shareportal.ShareIntent
import com.nostrvault.ui.theme.SecondaryText

/** "What I'm playing" (NIP-38): text, how long it shows, Publish. Twin: StatusReviewView.swift. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun StatusReviewContent(
    intent: ShareIntent,
    handler: StatusShareHandler,
    busy: Boolean,
    needsSwitch: Boolean,
    onSwitchAccount: (String) -> Unit,
    onDismiss: () -> Unit,
    onPublish: (text: String, expirySeconds: Long) -> Unit,
) {
    var text by remember(intent.id) { mutableStateOf(handler.initialText(intent)) }
    var expiry by remember(intent.id) { mutableLongStateOf(UserStatusPublisher.DEFAULT_EXPIRY) }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Share what I'm playing", style = MaterialTheme.typography.titleMedium)
        handler.url(intent)?.let { Text(it, maxLines = 1, overflow = TextOverflow.Ellipsis, color = SecondaryText) }
        OutlinedTextField(text, { text = it }, label = { Text("Status") }, maxLines = 3, modifier = Modifier.fillMaxWidth())
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            UserStatusPublisher.EXPIRY_CHOICES.forEach { s ->
                FilterChip(selected = expiry == s, onClick = { expiry = s }, label = { Text(if (s < 3600) "${s / 60} min" else "${s / 3600} h") })
            }
        }
        Text("Public: anyone who follows you can see it until it expires.", color = SecondaryText, style = MaterialTheme.typography.bodySmall)
        ShareAccountSwitchRow(intent, needsSwitch, onSwitchAccount)
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(onClick = { onPublish(text, expiry) }, enabled = !busy && !needsSwitch && text.isNotBlank()) { Text("Publish") }
            TextButton(onClick = onDismiss, enabled = !busy) { Text("Dismiss") }
        }
    }
}
