package com.nostrvault.ui.screens.shareportal

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.nostrvault.service.shareportal.handlers.ArticleClipShareHandler
import com.nostrvault.shareportal.ShareIntent
import com.nostrvault.ui.theme.SecondaryText

/**
 * Article clip: the quote + link that will become an article draft. Saving
 * publishes nothing. Twin: ArticleClipReviewView.swift.
 */
@Composable
internal fun ArticleClipReviewContent(
    intent: ShareIntent,
    handler: ArticleClipShareHandler,
    busy: Boolean,
    needsSwitch: Boolean,
    onSwitchAccount: (String) -> Unit,
    onDismiss: () -> Unit,
    onSave: (title: String, body: String, openEditor: Boolean) -> Unit,
) {
    val clip = remember(intent.id) { handler.clip(intent) }
    var title by remember(intent.id) { mutableStateOf(clip.title) }
    var body by remember(intent.id) { mutableStateOf(clip.body) }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Clip to an article draft", style = MaterialTheme.typography.titleMedium)
        OutlinedTextField(title, { title = it }, label = { Text("Title") }, singleLine = true, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(body, { body = it }, label = { Text("Draft") }, minLines = 4, maxLines = 12, modifier = Modifier.fillMaxWidth())
        Text(
            "A quote and a link, saved as a draft on this device. Nothing is posted. Open in editor saves it and opens it in New article; it also stays under Drafts.",
            color = SecondaryText, style = MaterialTheme.typography.bodySmall,
        )
        // The editor opens the active account's drafts, so the draft has to be for that account.
        ShareAccountSwitchRow(intent, needsSwitch, onSwitchAccount)
        val hasText = title.isNotBlank() || body.isNotBlank()
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(onClick = { onSave(title, body, true) }, enabled = !busy && !needsSwitch && hasText) {
                Text("Open in editor")
            }
            OutlinedButton(onClick = { onSave(title, body, false) }, enabled = !busy && hasText) {
                Text("Save draft")
            }
            TextButton(onClick = onDismiss, enabled = !busy) { Text("Dismiss") }
        }
    }
}
