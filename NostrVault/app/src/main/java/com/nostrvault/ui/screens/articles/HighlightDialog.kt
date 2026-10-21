package com.nostrvault.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.nostrvault.ui.theme.*

/** Trim the tapped paragraph to the part worth keeping, optionally add a thought. */
@Composable
internal fun HighlightDialog(
    initialPassage: String,
    onDismiss: () -> Unit,
    onPublish: (String, String) -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    var passage by remember { mutableStateOf(initialPassage) }
    var comment by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Highlight") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = passage,
                    onValueChange = { passage = it },
                    label = { Text("Delete what you don't want to keep") },
                    minLines = 3,
                    maxLines = 8,
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = comment,
                    onValueChange = { comment = it },
                    label = { Text("Your thoughts (optional)") },
                    maxLines = 4,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
        confirmButton = {
            TextButton(onClick = { onPublish(passage, comment) }, enabled = passage.isNotBlank()) {
                Text("Publish", color = if (passage.isNotBlank()) colors.primary else SecondaryText)
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
