package com.nostrvault.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.*

/**
 * The chat composer: relay media, the message field, the zap bolt and the
 * send arrow. Return sends, as the arrow does. iOS: LiveStreamPlayerView.composer.
 */
@Composable
internal fun LiveStreamComposer(
    text: String,
    onTextChange: (String) -> Unit,
    sending: Boolean,
    /** Hidden when ⚡️ is out of Appearance → Post buttons. */
    showZap: Boolean,
    onMedia: () -> Unit,
    onZap: () -> Unit,
    onSend: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalNostrVaultColors.current
    val canSend = text.isNotBlank() && !sending
    Row(verticalAlignment = Alignment.CenterVertically, modifier = modifier.fillMaxWidth()) {
        // Media from your relay's Blossom store, sent as its link.
        IconButton(onClick = onMedia) {
            Icon(NostrVaultIcons.Media, contentDescription = "Add media from your relay", tint = colors.primary)
        }
        OutlinedTextField(
            value = text,
            onValueChange = onTextChange,
            placeholder = { Text("Say something…", color = TertiaryText, fontSize = 14.sp) },
            singleLine = true,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
            keyboardActions = KeyboardActions(onSend = { if (canSend) onSend() }),
            modifier = Modifier.weight(1f),
            colors = OutlinedTextFieldDefaults.colors(
                focusedTextColor = PrimaryText,
                unfocusedTextColor = PrimaryText,
                cursorColor = colors.primary,
                focusedBorderColor = colors.primary,
            ),
        )
        if (showZap) {
            IconButton(onClick = onZap) {
                Icon(NostrVaultIcons.Zap, contentDescription = "Zap this stream", tint = ZapOrange)
            }
        }
        IconButton(onClick = onSend, enabled = canSend) {
            Icon(
                NostrVaultIcons.ArrowUpCircleFill,
                contentDescription = "Send message",
                tint = if (text.isBlank()) SecondaryText else colors.primary,
                modifier = Modifier.size(28.dp),
            )
        }
    }
}
