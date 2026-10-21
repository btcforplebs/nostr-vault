package com.nostrvault.ui.screens

import androidx.compose.animation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.*
import java.net.URL

// ══════════════════════════════════════════════════════════════════
// Step: Relay Choice
// ══════════════════════════════════════════════════════════════════

@Composable
internal fun RelayChoiceStep(viewModel: SetupWizardViewModel) {
    val useExternal by viewModel.useExternalRelay.collectAsState()
    val relayInput by viewModel.externalRelayInput.collectAsState()
    val blossomInput by viewModel.externalBlossomInput.collectAsState()
    val error by viewModel.error.collectAsState()

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            text = "Where should your notes live?",
            color = PrimaryText,
            fontSize = 20.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = "You can change this later in Settings > Advanced.",
            color = SecondaryText,
            fontSize = 14.sp,
        )

        Spacer(Modifier.height(24.dp))

        WizardOptionCard(
            title = "Built-in Relay",
            subtitle = "Recommended -- your own relay and media server inside this app",
            selected = !useExternal,
            onClick = { viewModel.setUseExternalRelay(false) },
            modifier = Modifier.fillMaxWidth(),
        )

        Spacer(Modifier.height(12.dp))

        WizardOptionCard(
            title = "A Relay You Already Run",
            subtitle = "A relay app on this phone, e.g. Citrine, or your own relay elsewhere, " +
                "e.g. Nostr Vault for Mac. The built-in relay never starts.",
            selected = useExternal,
            onClick = { viewModel.setUseExternalRelay(true) },
            modifier = Modifier.fillMaxWidth(),
        )

        if (useExternal) {
            Spacer(Modifier.height(16.dp))
            OutlinedTextField(
                value = relayInput,
                onValueChange = viewModel::setExternalRelayInput,
                label = { Text("Relay URL") },
                placeholder = { Text("ws://127.0.0.1:4869 or wss://your.domain") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                modifier = Modifier.fillMaxWidth(),
                colors = wizardTextFieldColors(),
            )
            Spacer(Modifier.height(8.dp))
            OutlinedTextField(
                value = blossomInput,
                onValueChange = viewModel::setExternalBlossomInput,
                label = { Text("Blossom URL (optional)") },
                placeholder = { Text("https://your.domain") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                modifier = Modifier.fillMaxWidth(),
                colors = wizardTextFieldColors(),
            )
            Spacer(Modifier.height(8.dp))
            Text(
                text = "Setup skips importing your notes and media, since those fill the " +
                    "built-in relay. Notifications and the Popular feed need the built-in " +
                    "relay and stay off.",
                color = SecondaryText,
                fontSize = 12.sp,
            )
        }

        error?.let {
            Spacer(Modifier.height(8.dp))
            Text(text = it, color = ErrorRed, fontSize = 13.sp)
        }

        Spacer(Modifier.height(32.dp))

        WizardPrimaryButton(
            text = "Continue",
            onClick = viewModel::advanceFromRelayChoice,
        )
    }
}
