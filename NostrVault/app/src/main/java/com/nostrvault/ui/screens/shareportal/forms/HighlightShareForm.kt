package com.nostrvault.ui.screens.shareportal.forms

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.nostrvault.ui.components.ProseKeyboardOptions
import com.nostrvault.ui.theme.SecondaryText

/**
 * The share sheet's Highlight form: trim the passage, add a thought. Nothing
 * is published from here; Send queues it for the app's review card. Twin:
 * HighlightShareForm.swift.
 */
@Composable
internal fun HighlightShareForm(
    url: String?,
    initialPassage: String,
    accountLine: String?,
    onBack: () -> Unit,
    onSend: (passage: String, comment: String) -> Unit,
) {
    var passage by remember { mutableStateOf(initialPassage) }
    var comment by remember { mutableStateOf("") }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Highlight", style = MaterialTheme.typography.titleSmall)
        url?.let { Text(it, maxLines = 1, overflow = TextOverflow.Ellipsis, color = SecondaryText) }
        accountLine?.let { Text(it, color = SecondaryText) }
        OutlinedTextField(
            value = passage,
            onValueChange = { passage = it },
            label = { Text(if (initialPassage.isBlank()) "Paste the part worth keeping" else "Delete what you don't want to keep") },
            minLines = 3,
            maxLines = 8,
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = comment,
            onValueChange = { comment = it },
            label = { Text("Your thoughts (optional)") },
            keyboardOptions = ProseKeyboardOptions,
            maxLines = 4,
            modifier = Modifier.fillMaxWidth(),
        )
        Text("You'll review it in Nostr Vault before it's published.", color = SecondaryText,
            style = MaterialTheme.typography.bodySmall)
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(onClick = { onSend(passage, comment) }, enabled = passage.isNotBlank()) { Text("Send to Nostr Vault") }
            TextButton(onClick = onBack) { Text("Back") }
        }
    }
}
