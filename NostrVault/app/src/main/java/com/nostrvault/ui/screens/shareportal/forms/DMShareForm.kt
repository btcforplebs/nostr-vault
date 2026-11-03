package com.nostrvault.ui.screens.shareportal.forms

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.nostrvault.shareportal.ShareContactsSnapshot
import com.nostrvault.ui.components.ProseKeyboardOptions
import com.nostrvault.ui.theme.SecondaryText

/**
 * Send privately from the share sheet: the message (editable) and, when this
 * account has sent shares privately before, one of those people. Queued, not
 * sent: the app shows the recipient and text again and sends only from
 * there. Twin: DMShareForm.swift.
 */
@Composable
internal fun DMShareForm(
    initialMessage: String,
    recent: List<ShareContactsSnapshot.Contact>,
    onBack: () -> Unit,
    onSend: (message: String, to: String?) -> Unit,
) {
    var message by remember { mutableStateOf(initialMessage) }
    var to by remember { mutableStateOf<String?>(null) }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Send privately", style = MaterialTheme.typography.titleSmall)
        OutlinedTextField(
            value = message,
            onValueChange = { message = it },
            label = { Text("Message") },
            keyboardOptions = ProseKeyboardOptions,
            minLines = 2,
            maxLines = 6,
            modifier = Modifier.fillMaxWidth(),
        )
        if (recent.isNotEmpty()) {
            Text("To", style = MaterialTheme.typography.labelLarge)
            recent.forEach { c ->
                Row(Modifier.fillMaxWidth().clickable { to = if (to == c.npub) null else c.npub }) {
                    RadioButton(selected = to == c.npub, onClick = { to = if (to == c.npub) null else c.npub })
                    Text(c.name.ifBlank { c.npub.take(16) + "…" }, Modifier.padding(top = 12.dp))
                }
            }
        }
        Text("You'll pick or check who it goes to in the app, and it is sent only from there.",
            color = SecondaryText, style = MaterialTheme.typography.bodySmall)
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(onClick = { onSend(message, to) }, enabled = message.isNotBlank()) { Text("Send to Nostr Vault") }
            TextButton(onClick = onBack) { Text("Back") }
        }
    }
}
