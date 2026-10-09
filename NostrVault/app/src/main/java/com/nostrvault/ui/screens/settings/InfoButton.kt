package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.layout.size
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.SecondaryText

/**
 * The (i) next to a setting: tap it for one or two sentences about what the
 * setting does, instead of a grey caption under the row.
 *
 * Mirrors `InfoButton` on the Swift side; the words come from [SettingsHelp],
 * which shares its keys with iOS and macOS.
 */
@Composable
fun InfoButton(topic: SettingsHelp, modifier: Modifier = Modifier) {
    var shown by remember { mutableStateOf(false) }

    // IconButton keeps the 48dp touch target; only the glyph is small.
    IconButton(onClick = { shown = true }, modifier = modifier) {
        Icon(
            imageVector = NostrVaultIcons.Info,
            contentDescription = "About ${topic.title}",
            tint = SecondaryText,
            modifier = Modifier.size(18.dp),
        )
    }

    if (shown) {
        AlertDialog(
            onDismissRequest = { shown = false },
            title = { Text(topic.title) },
            text = { Text(topic.text) },
            confirmButton = {
                TextButton(onClick = { shown = false }) { Text("OK") }
            },
        )
    }
}
