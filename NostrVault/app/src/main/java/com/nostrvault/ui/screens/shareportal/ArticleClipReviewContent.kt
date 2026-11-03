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
    onDismiss: () -> Unit,
    onSave: (title: String, body: String) -> Unit,
) {
    val clip = remember(intent.id) { handler.clip(intent) }
    var title by remember(intent.id) { mutableStateOf(clip.title) }
    var body by remember(intent.id) { mutableStateOf(clip.body) }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Clip to an article draft", style = MaterialTheme.typography.titleMedium)
        OutlinedTextField(title, { title = it }, label = { Text("Title") }, singleLine = true, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(body, { body = it }, label = { Text("Draft") }, minLines = 4, maxLines = 12, modifier = Modifier.fillMaxWidth())
        Text(
            "A quote and a link, saved as a draft on this device. Nothing is posted. Find it under New article → Drafts.",
            color = SecondaryText, style = MaterialTheme.typography.bodySmall,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(onClick = { onSave(title, body) }, enabled = !busy && (title.isNotBlank() || body.isNotBlank())) {
                Text("Save draft")
            }
            TextButton(onClick = onDismiss, enabled = !busy) { Text("Dismiss") }
        }
    }
}
