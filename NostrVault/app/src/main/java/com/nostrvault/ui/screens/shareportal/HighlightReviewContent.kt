package com.nostrvault.ui.screens.shareportal

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.nostrvault.service.shareportal.handlers.HighlightShareHandler
import com.nostrvault.shareportal.ShareIntent
import com.nostrvault.ui.components.ProseKeyboardOptions
import com.nostrvault.ui.theme.SecondaryText

/**
 * Review card for a shared highlight: the passage and comment from the share
 * sheet, still editable, and an explicit Publish. Twin: HighlightReviewView.swift.
 */
@Composable
internal fun HighlightReviewContent(
    intent: ShareIntent,
    handler: HighlightShareHandler,
    busy: Boolean,
    needsSwitch: Boolean,
    onSwitchAccount: (String) -> Unit,
    onPublish: (passage: String, comment: String) -> Unit,
    onDismiss: () -> Unit,
) {
    var passage by remember(intent.id) { mutableStateOf(handler.initialPassage(intent)) }
    var comment by remember(intent.id) { mutableStateOf(intent.form["comment"].orEmpty()) }
    val url = handler.sourceUrl(intent)
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Highlight", style = MaterialTheme.typography.titleMedium)
        (intent.source.title ?: url)?.let { Text(it, maxLines = 2, overflow = TextOverflow.Ellipsis, color = SecondaryText) }
        OutlinedTextField(
            value = passage,
            onValueChange = { passage = it },
            label = { Text("Highlight") },
            minLines = 3,
            maxLines = 10,
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
        Text("Highlights are public.", color = SecondaryText, style = MaterialTheme.typography.bodySmall)
        val wanted = intent.account
        if (wanted != null && needsSwitch) {
            Text("This was shared for another of your accounts.", color = SecondaryText)
            OutlinedButton(onClick = { onSwitchAccount(wanted) }) { Text("Switch to that account") }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(
                onClick = { onPublish(passage, comment) },
                enabled = !busy && passage.isNotBlank() && !needsSwitch,
            ) { Text(if (busy) "Publishing…" else "Publish") }
            TextButton(onClick = onDismiss, enabled = !busy) { Text("Dismiss") }
        }
    }
}
