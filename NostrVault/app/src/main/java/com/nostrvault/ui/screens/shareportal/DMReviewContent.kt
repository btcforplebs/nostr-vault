package com.nostrvault.ui.screens.shareportal

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import com.nostrvault.service.shareportal.handlers.DMShareHandler
import com.nostrvault.shareportal.ShareIntent
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.components.ProseKeyboardOptions
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.SecondaryText

/**
 * Review card for "Send privately": who it goes to and the exact text. Sent
 * as a NIP-17 private message only on Send. Twin: DMReviewView.swift.
 */
@Composable
internal fun DMReviewContent(
    intent: ShareIntent,
    needsSwitch: Boolean,
    onSwitchAccount: (String) -> Unit,
    onSent: () -> Unit,
    onDismiss: () -> Unit,
    viewModel: DMReviewViewModel = hiltViewModel(key = "share-dm-${intent.id}"),
) {
    val busy by viewModel.busy.collectAsState()
    val error by viewModel.error.collectAsState()
    val profiles by viewModel.profiles.collectAsState()
    var message by remember(intent.id) { mutableStateOf(DMShareHandler.initialMessage(intent)) }
    var recipient by remember(intent.id) {
        mutableStateOf(DMShareHandler.initialRecipientNpub(intent)?.let(viewModel::npubToHex))
    }
    var query by remember(intent.id) { mutableStateOf("") }

    Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Send privately", style = MaterialTheme.typography.titleMedium)
        Text("To", style = MaterialTheme.typography.titleSmall)
        val to = recipient
        if (to != null) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Person(to, profiles[to]?.bestName, profiles[to]?.pictureURL, viewModel.hexToNpub(to), Modifier.weight(1f))
                TextButton(onClick = { recipient = null }, enabled = !busy) { Text("Change") }
            }
        } else {
            OutlinedTextField(value = query, onValueChange = { query = it }, label = { Text("Name or npub") },
                singleLine = true, modifier = Modifier.fillMaxWidth())
            viewModel.candidates(intent, query).forEach { hex ->
                Person(hex, profiles[hex]?.bestName, profiles[hex]?.pictureURL, viewModel.hexToNpub(hex),
                    Modifier.fillMaxWidth().clickable { recipient = hex; query = "" })
            }
        }
        OutlinedTextField(
            value = message,
            onValueChange = { message = it },
            label = { Text("Message") },
            keyboardOptions = ProseKeyboardOptions,
            minLines = 3,
            maxLines = 10,
            modifier = Modifier.fillMaxWidth(),
        )
        Text(
            if (intent.files.isEmpty()) "Only they can read it."
            else "Only they can read it. Files aren't sent privately yet; only the text goes.",
            color = SecondaryText, style = MaterialTheme.typography.bodySmall,
        )
        val wanted = intent.account
        if (wanted != null && needsSwitch) {
            Text("This was shared for another of your accounts.", color = SecondaryText)
            OutlinedButton(onClick = { onSwitchAccount(wanted) }) { Text("Switch to that account") }
        }
        error?.let { Text(it, color = ErrorRed) }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(
                onClick = { recipient?.let { viewModel.send(intent, message, it, onSent) } },
                enabled = !busy && recipient != null && message.isNotBlank() && !needsSwitch,
            ) { Text(if (busy) "Sending…" else "Send privately") }
            TextButton(onClick = onDismiss, enabled = !busy) { Text("Dismiss") }
        }
    }
}

@Composable
private fun Person(hex: String, name: String?, picture: String?, npub: String?, modifier: Modifier = Modifier) {
    Row(modifier.padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        AvatarImage(url = picture, pubkey = hex, size = 28.dp, displayName = name)
        Column {
            Text(name?.takeIf { it.isNotBlank() } ?: hex.take(8))
            npub?.let { Text(it.take(20) + "…", color = SecondaryText, style = MaterialTheme.typography.bodySmall) }
        }
    }
}
