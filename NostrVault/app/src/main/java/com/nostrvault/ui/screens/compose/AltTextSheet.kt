package com.nostrvault.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.*

/**
 * Sheet for writing one attachment's NIP-92 `alt` text.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun AltTextSheet(
    attachment: Attachment,
    onDismiss: () -> Unit,
    onSave: (String) -> Unit,
) {
    var text by remember(attachment.id) { mutableStateOf(attachment.altText) }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                text = "Describe this media",
                fontSize = 18.sp,
                fontWeight = FontWeight.SemiBold,
                color = PrimaryText,
            )
            Text(
                text = "Published as the image's ALT text. Screen readers read this instead of the picture.",
                fontSize = 13.sp,
                color = SecondaryText,
            )
            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 100.dp)
                    .semantics { contentDescription = "Media description" },
                placeholder = { Text("A cat asleep on a keyboard") },
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.End,
            ) {
                TextButton(onClick = onDismiss) { Text("Cancel") }
                Spacer(modifier = Modifier.width(8.dp))
                Button(onClick = { onSave(text) }) { Text("Save") }
            }
        }
    }
}
