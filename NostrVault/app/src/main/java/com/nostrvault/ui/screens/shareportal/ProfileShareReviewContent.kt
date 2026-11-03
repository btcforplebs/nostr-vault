package com.nostrvault.ui.screens.shareportal

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import com.nostrvault.shareportal.ShareIntent
import com.nostrvault.ui.theme.SecondaryText

/**
 * Review card for a shared profile: who it names, then Follow or Block. Nothing is signed until one is tapped, and
 * Block asks once more. Twin: ProfileShareReviewView.swift.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ProfileShareReviewContent(
    intent: ShareIntent,
    needsSwitch: Boolean,
    onSwitchAccount: (String) -> Unit,
    onDismiss: () -> Unit,
    viewModel: ProfileShareReviewViewModel = hiltViewModel(),
) {
    val people = remember(intent.id) { viewModel.people(intent) }
    val profiles by viewModel.profiles.collectAsState()
    val followed by viewModel.followed.collectAsState()
    var picked by remember(intent.id) { mutableIntStateOf(0) }
    var confirmBlock by remember(intent.id) { mutableStateOf(false) }
    var message by remember(intent.id) { mutableStateOf<String?>(null) }
    val person = people.getOrNull(picked)
    val name: (String) -> String = { hex -> profiles[hex]?.bestName ?: "${hex.take(8)}..." }
    val isSelf = person != null && person.equals(viewModel.activeHex(), ignoreCase = true)
    val ready = person != null && !needsSwitch && !isSelf && viewModel.canSign()

    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Profile", style = MaterialTheme.typography.titleMedium)
        if (person == null) {
            Text("This share doesn't name a Nostr profile.", color = SecondaryText)
        } else {
            if (people.size > 1) {
                Text("This share names ${people.size} people.", color = SecondaryText)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    people.take(5).forEachIndexed { i, hex ->
                        FilterChip(selected = i == picked, onClick = { picked = i }, label = { Text(name(hex), maxLines = 1) })
                    }
                }
            }
            Text(name(person), style = MaterialTheme.typography.titleLarge)
            profiles[person]?.about?.takeIf { it.isNotBlank() }?.let {
                Text(it, color = SecondaryText, maxLines = 3, overflow = TextOverflow.Ellipsis)
            }
            if (isSelf) Text("That's you.", color = SecondaryText)
        }
        val wanted = intent.account
        if (wanted != null && needsSwitch) {
            Text("This was shared for another of your accounts.", color = SecondaryText)
            OutlinedButton(onClick = { onSwitchAccount(wanted) }) { Text("Switch to that account") }
        } else if (!viewModel.canSign()) {
            Text("This account is read-only here.", color = SecondaryText)
        }
        message?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        Text(
            "Follow and Block change your follow list and your mute list, which other Nostr apps read too.",
            color = SecondaryText, style = MaterialTheme.typography.bodySmall,
        )
        if (person != null) {
            val following = person in followed
            val blocked = viewModel.isBlocked(person)
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Button(
                    onClick = { message = null; viewModel.follow(person, onDismiss) { message = it } },
                    enabled = ready && !following,
                ) { Text(if (following) "Following" else "Follow") }
                OutlinedButton(onClick = { confirmBlock = true }, enabled = ready && !blocked) {
                    Text(if (blocked) "Blocked" else "Block")
                }
                TextButton(onClick = onDismiss) { Text("Dismiss") }
            }
        } else {
            TextButton(onClick = onDismiss) { Text("Dismiss") }
        }
    }
    if (confirmBlock && person != null) {
        AlertDialog(
            onDismissRequest = { confirmBlock = false },
            title = { Text("Block ${name(person)}?") },
            text = { Text("Their notes are hidden everywhere you use this account.") },
            confirmButton = {
                TextButton(onClick = { confirmBlock = false; viewModel.block(person, name(person), onDismiss) }) { Text("Block") }
            },
            dismissButton = { TextButton(onClick = { confirmBlock = false }) { Text("Cancel") } },
        )
    }
}
