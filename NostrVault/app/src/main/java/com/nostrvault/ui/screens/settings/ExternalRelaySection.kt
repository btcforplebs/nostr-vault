package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.relay.HavenConfig
import com.nostrvault.relay.normalizeExternalBlossomURL
import com.nostrvault.relay.normalizeExternalRelayURL
import com.nostrvault.ui.theme.*

/**
 * Android-only: run the app against a relay and Blossom server that live in
 * another app on the phone (e.g. Citrine), keeping client and storage in
 * separate sandboxes. Edits are a draft until applied, because every service
 * picks its relay URLs up once at start — applying restarts the app.
 */
@Composable
fun ExternalRelaySection(
    config: HavenConfig,
    onApply: (enabled: Boolean, relayURL: String, blossomURL: String) -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    var enabled by remember(config.useExternalRelay) { mutableStateOf(config.useExternalRelay) }
    var relayURL by remember(config.externalRelayURL) { mutableStateOf(config.externalRelayURL) }
    var blossomURL by remember(config.externalBlossomURL) { mutableStateOf(config.externalBlossomURL) }

    val relayValid = normalizeExternalRelayURL(relayURL) != null
    val blossomValid = blossomURL.isBlank() || normalizeExternalBlossomURL(blossomURL) != null
    val changed = enabled != config.useExternalRelay ||
        (enabled && (relayURL.trim() != config.externalRelayURL || blossomURL.trim() != config.externalBlossomURL))
    val canApply = changed && (!enabled || (relayValid && blossomValid))

    val fieldColors = OutlinedTextFieldDefaults.colors(
        focusedTextColor = PrimaryText, unfocusedTextColor = PrimaryText,
        cursorColor = colors.primary, focusedBorderColor = colors.primary,
    )

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
    ) {
        Text("Use External Relay", color = PrimaryText, fontSize = 15.sp, modifier = Modifier.weight(1f))
        Switch(
            checked = enabled,
            onCheckedChange = { enabled = it },
            colors = SwitchDefaults.colors(
                checkedThumbColor = PrimaryText,
                checkedTrackColor = colors.primary,
            ),
        )
    }

    if (enabled) {
        OutlinedTextField(
            value = relayURL,
            onValueChange = { relayURL = it },
            label = { Text("Relay URL") },
            placeholder = { Text("ws://127.0.0.1:4869") },
            isError = relayURL.isNotBlank() && !relayValid,
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
            modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            colors = fieldColors,
        )
        OutlinedTextField(
            value = blossomURL,
            onValueChange = { blossomURL = it },
            label = { Text("Blossom URL (optional)") },
            placeholder = { Text("http://127.0.0.1:port") },
            isError = !blossomValid,
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
            modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            colors = fieldColors,
        )
    }

    Text(
        text = "Turns off the built-in relay and Blossom server and uses another app's on this " +
            "phone instead, so the client and your data stay in separate sandboxes. The built-in " +
            "relay also gathers your mentions, replies and zaps from other relays, raises " +
            "notifications and ranks the Popular feed; an external relay only has what reaches " +
            "it, and those features pause. Drafts stay on this phone. Without a Blossom URL, " +
            "media goes to your mirror servers only.",
        color = SecondaryText,
        fontSize = 12.sp,
        modifier = Modifier.padding(top = 6.dp),
    )

    Button(
        onClick = { onApply(enabled, relayURL.trim(), blossomURL.trim()) },
        enabled = canApply,
        colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
        modifier = Modifier.padding(top = 8.dp),
    ) { Text("Apply & Restart App") }
}
