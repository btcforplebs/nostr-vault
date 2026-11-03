package com.nostrvault.ui.screens.shareportal

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.nostrvault.service.LabelPublisher
import com.nostrvault.service.shareportal.handlers.LabelShareHandler
import com.nostrvault.shareportal.ShareIntent
import com.nostrvault.ui.theme.SecondaryText

/** Flag a link (NIP-32) with one fixed label. Twin: LabelReviewView.swift. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun LabelReviewContent(
    intent: ShareIntent,
    handler: LabelShareHandler,
    busy: Boolean,
    needsSwitch: Boolean,
    onSwitchAccount: (String) -> Unit,
    onDismiss: () -> Unit,
    onPublish: (label: String, comment: String) -> Unit,
) {
    var label by remember(intent.id) { mutableStateOf<String?>(null) }
    var comment by remember(intent.id) { mutableStateOf("") }
    val url = handler.url(intent)
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Flag this link", style = MaterialTheme.typography.titleMedium)
        Text(url ?: "No link to flag", maxLines = 2, overflow = TextOverflow.Ellipsis, color = SecondaryText)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            LabelPublisher.LABELS.forEach { l ->
                FilterChip(selected = label == l, onClick = { label = l }, label = { Text(l) })
            }
        }
        OutlinedTextField(comment, { comment = it }, label = { Text("Why (optional)") }, maxLines = 3, modifier = Modifier.fillMaxWidth())
        Text("Public, and about someone else's site: anyone can see that you labelled it.",
            color = SecondaryText, style = MaterialTheme.typography.bodySmall)
        ShareAccountSwitchRow(intent, needsSwitch, onSwitchAccount)
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            val chosen = label
            Button(onClick = { chosen?.let { onPublish(it, comment) } }, enabled = !busy && !needsSwitch && chosen != null && url != null) {
                Text("Publish")
            }
            TextButton(onClick = onDismiss, enabled = !busy) { Text("Dismiss") }
        }
    }
}
