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
import com.nostrvault.relay.BlossomUploadProbe
import com.nostrvault.relay.BlossomUploadSupport
import com.nostrvault.relay.HavenConfig
import com.nostrvault.relay.normalizeExternalBlossomURL
import com.nostrvault.relay.normalizeExternalRelayURL
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Android-only: run the app against a relay and Blossom server it does not
 * host itself — another app on the phone (Citrine) or a relay of your own
 * elsewhere (Nostr Vault for Mac on a domain). Edits are a draft until
 * applied, because every service picks its relay URLs up once at start —
 * applying restarts the app. A Blossom address is checked for uploads first:
 * a read-only cache (Morganite) would make every save fail.
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

    val scope = rememberCoroutineScope()
    var checking by remember { mutableStateOf(false) }
    var blossomProblem by remember(blossomURL) { mutableStateOf<String?>(null) }
    var unreachableOk by remember(blossomURL) { mutableStateOf(false) }

    fun apply() {
        val base = normalizeExternalBlossomURL(blossomURL)
        if (!enabled || base == null || unreachableOk) {
            onApply(enabled, relayURL.trim(), blossomURL.trim())
            return
        }
        checking = true
        scope.launch {
            val support = withContext(Dispatchers.IO) { BlossomUploadProbe.check(base) }
            checking = false
            when (support) {
                BlossomUploadSupport.ACCEPTS_UPLOADS -> onApply(enabled, relayURL.trim(), blossomURL.trim())
                BlossomUploadSupport.READ_ONLY -> blossomProblem =
                    "This server can't take uploads. It looks like a read-only cache such as " +
                        "Morganite. Put a Blossom server that takes uploads here; Morganite works " +
                        "as a cache under Media."
                BlossomUploadSupport.NEEDS_HTTPS -> blossomProblem =
                    "This server only speaks https. Change http:// to https://."
                BlossomUploadSupport.UNREACHABLE -> {
                    blossomProblem = "Couldn't reach this Blossom server. Tap Apply again to use it anyway."
                    unreachableOk = true
                }
            }
        }
    }

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
            enabled = !checking,
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
            placeholder = { Text("ws://127.0.0.1:4869 or wss://your.domain") },
            isError = relayURL.isNotBlank() && !relayValid,
            singleLine = true,
            enabled = !checking, // the probe applies what was checked
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
            modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            colors = fieldColors,
        )
        OutlinedTextField(
            value = blossomURL,
            onValueChange = { blossomURL = it },
            label = { Text("Blossom URL (optional)") },
            placeholder = { Text("https://your.domain") },
            isError = !blossomValid || blossomProblem != null,
            supportingText = blossomProblem?.let { msg -> { Text(msg) } },
            singleLine = true,
            enabled = !checking, // the probe applies what was checked
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
            modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            colors = fieldColors,
        )
    }

    Text(
        text = "Turns off the built-in relay and Blossom server and uses yours instead: another " +
            "app on this phone (Citrine, ws://127.0.0.1:4869) or your own relay elsewhere, such as " +
            "Nostr Vault for Mac (wss:// and https:// on its domain). Addresses off this phone " +
            "need wss:// and https://; .onion addresses don't work yet. The built-in " +
            "relay also gathers your mentions, replies and zaps from other relays, raises " +
            "notifications and ranks the Popular feed; an external relay only has what reaches " +
            "it, and those features pause. Drafts stay on this phone. Without a Blossom URL, " +
            "media goes to your mirror servers only.",
        color = SecondaryText,
        fontSize = 12.sp,
        modifier = Modifier.padding(top = 6.dp),
    )

    Button(
        onClick = { apply() },
        enabled = canApply && !checking,
        colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
        modifier = Modifier.padding(top = 8.dp),
    ) { Text(if (checking) "Checking Blossom…" else "Apply & Restart App") }
}
