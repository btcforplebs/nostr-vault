package com.nostrvault.tutorials

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.WindowBackground

/**
 * Settings → Tutorials (iOS `TutorialsSettingsView`): every tutorial in this
 * build, whether it's been seen, and Replay. [onReplay] leaves Settings for
 * the tutorial's page, where its card is waiting.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TutorialsSettingsScreen(
    account: String,
    onBack: () -> Unit,
    onReplay: (TutorialID) -> Unit,
) {
    // Re-read statuses whenever one is saved.
    val revision by TutorialCenter.saves.collectAsState()
    var confirmingReset by remember { mutableStateOf(false) }
    val tutorials = TutorialID.entries.filter { it.isAvailable }
    val primary = LocalNostrVaultColors.current.primary

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Tutorials") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(NostrVaultIcons.Back, contentDescription = "Back")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = WindowBackground,
                    titleContentColor = PrimaryText,
                    navigationIconContentColor = PrimaryText,
                ),
            )
        },
        containerColor = WindowBackground,
    ) { padding ->
        Column(
            Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
        ) {
            tutorials.forEach { id ->
                val status = remember(revision, account, id) { TutorialCenter.status(id, account) }
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 10.dp),
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(id.title, color = PrimaryText, fontSize = 16.sp)
                        Text(statusText(status), color = SecondaryText, fontSize = 13.sp)
                    }
                    Spacer(Modifier.width(12.dp))
                    OutlinedButton(
                        onClick = {
                            TutorialCenter.replay(id)
                            onReplay(id)
                        },
                        enabled = account.isNotEmpty(),
                        modifier = Modifier.semantics { contentDescription = "Replay ${id.title}" },
                    ) {
                        Text("Replay", color = primary)
                    }
                }
            }
            Text(
                "Each tutorial shows once, the first time you open its page. Skip any of them and replay it here.",
                color = SecondaryText,
                fontSize = 13.sp,
                modifier = Modifier.padding(top = 4.dp, bottom = 24.dp),
            )
            TextButton(onClick = { confirmingReset = true }, enabled = account.isNotEmpty()) {
                Text("Show All Again", color = ErrorRed, fontSize = 16.sp)
            }
            Text(
                "Each tutorial shows again the next time you open its page. Your follows aren't changed.",
                color = SecondaryText,
                fontSize = 13.sp,
            )
        }
    }

    if (confirmingReset) {
        AlertDialog(
            onDismissRequest = { confirmingReset = false },
            title = { Text("Show all tutorials again?") },
            confirmButton = {
                TextButton(onClick = {
                    TutorialCenter.resetAll(account)
                    confirmingReset = false
                }) { Text("Show All Again", color = ErrorRed) }
            },
            dismissButton = {
                TextButton(onClick = { confirmingReset = false }) { Text("Cancel") }
            },
        )
    }
}

private fun statusText(status: TutorialStatus): String = when (status) {
    TutorialStatus.NOT_STARTED -> "Not seen yet"
    TutorialStatus.SKIPPED -> "Skipped"
    TutorialStatus.DONE -> "Done"
}
