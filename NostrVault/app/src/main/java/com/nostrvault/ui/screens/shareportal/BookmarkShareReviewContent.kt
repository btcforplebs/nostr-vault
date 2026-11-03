package com.nostrvault.ui.screens.shareportal

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import com.nostrvault.service.shareportal.handlers.BookmarkShareHandler
import com.nostrvault.shareportal.ShareIntent
import com.nostrvault.ui.theme.SecondaryText

/**
 * Review card for Save for later: the link, Public or Private, and an explicit Save. Nothing is signed until Save.
 * Twin: BookmarkShareReviewView.swift.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun BookmarkShareReviewContent(
    intent: ShareIntent,
    needsSwitch: Boolean,
    onSwitchAccount: (String) -> Unit,
    onDismiss: () -> Unit,
    viewModel: BookmarkShareReviewViewModel = hiltViewModel(),
) {
    val url = remember(intent.id) { BookmarkShareHandler.url(intent) }
    var privately by remember(intent.id) { mutableStateOf(false) }
    val saving by viewModel.saving.collectAsState()
    val message by viewModel.message.collectAsState()
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Save for later", style = MaterialTheme.typography.titleMedium)
        if (url == null) {
            Text("This share has no web link to save.", color = SecondaryText)
        } else {
            intent.source.title?.takeIf { it.isNotBlank() }?.let { Text(it, maxLines = 2, overflow = TextOverflow.Ellipsis) }
            Text(url, color = SecondaryText, maxLines = 3, overflow = TextOverflow.Ellipsis)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilterChip(selected = !privately, onClick = { privately = false }, label = { Text("Public") })
                FilterChip(selected = privately, onClick = { privately = true }, label = { Text("Private") })
            }
            Text(
                if (privately) "Only you can read it: it is encrypted to your own key on your Bookmarks list."
                else "Anyone can see it on your Bookmarks list.",
                color = SecondaryText, style = MaterialTheme.typography.bodySmall,
            )
        }
        val wanted = intent.account
        if (wanted != null && needsSwitch) {
            Text("This was shared for another of your accounts.", color = SecondaryText)
            OutlinedButton(onClick = { onSwitchAccount(wanted) }) { Text("Switch to that account") }
        } else if (!viewModel.canSign) {
            Text("This account is read-only here.", color = SecondaryText)
        }
        message?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(
                onClick = { url?.let { viewModel.save(it, privately, onDismiss) } },
                enabled = url != null && !saving && !needsSwitch && viewModel.canSign,
            ) { Text(if (saving) "Saving…" else "Save for later") }
            TextButton(onClick = onDismiss, enabled = !saving) { Text("Dismiss") }
        }
    }
}
