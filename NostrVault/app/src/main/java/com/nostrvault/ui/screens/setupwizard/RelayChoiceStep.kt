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
import com.nostrvault.setup.CitrineDetect
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
    val citrineInstalled by viewModel.citrineInstalled.collectAsState()

    if (citrineInstalled) {
        CitrineChoice(viewModel, useCitrine = useExternal, error = error)
        return
    }

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
                label = { Text("Media server URL (optional)") },
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

/** Citrine is on this phone: one choice, Nostr Vault or Citrine. */
@Composable
private fun CitrineChoice(viewModel: SetupWizardViewModel, useCitrine: Boolean, error: String?) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            text = "Citrine is on this phone",
            color = PrimaryText,
            fontSize = 20.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = "Which one should keep your notes? You can change this later in Settings > Advanced.",
            color = SecondaryText,
            fontSize = 14.sp,
        )

        Spacer(Modifier.height(24.dp))

        WizardOptionCard(
            title = "Use Nostr Vault",
            subtitle = "Recommended -- your notes and media live in this app, " +
                "with notifications and the Popular feed",
            selected = !useCitrine,
            onClick = { viewModel.chooseCitrine(false) },
            modifier = Modifier.fillMaxWidth(),
        )

        Spacer(Modifier.height(12.dp))

        WizardOptionCard(
            title = "Use Citrine",
            subtitle = "Your notes stay in Citrine (${CitrineDetect.RELAY_URL}), so there is no " +
                "second copy. Setup skips the import. Notifications and the Popular feed stay off.",
            selected = useCitrine,
            onClick = { viewModel.chooseCitrine(true) },
            modifier = Modifier.fillMaxWidth(),
        )

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
