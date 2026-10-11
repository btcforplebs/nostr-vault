package com.nostrvault.ui.screens

import androidx.compose.animation.*
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.*
import java.net.URL

// ══════════════════════════════════════════════════════════════════
// Step 4: Relay Configuration (editable)
// ══════════════════════════════════════════════════════════════════

@Composable
internal fun RelayStep(viewModel: SetupWizardViewModel) {
    val relays by viewModel.wizardRelays.collectAsState()
    val newRelayInput by viewModel.newRelayInput.collectAsState()
    val macRelayInput by viewModel.macRelayInput.collectAsState()
    val focusManager = LocalFocusManager.current

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            text = "Relay Configuration",
            color = PrimaryText,
            fontSize = 20.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = "These relays will be used for your feed. Your personal relay also runs on-device.",
            color = SecondaryText,
            fontSize = 14.sp,
            textAlign = TextAlign.Center,
        )

        Spacer(Modifier.height(20.dp))

        // Haven relay section
        WizardCard {
            Column(modifier = Modifier.padding(4.dp)) {
                Text(
                    text = "Sync with Haven Relay",
                    color = PrimaryText,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.Medium,
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    text = "If you already run a Haven relay, enter its URL to stay synced.",
                    color = SecondaryText,
                    fontSize = 13.sp,
                )
                Spacer(Modifier.height(10.dp))
                OutlinedTextField(
                    value = macRelayInput,
                    onValueChange = viewModel::setMacRelayInput,
                    placeholder = { Text("wss://relay.yourdomain.com", color = TertiaryText) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { focusManager.clearFocus() }),
                    colors = wizardTextFieldColors(),
                    shape = RoundedCornerShape(8.dp),
                    modifier = Modifier.fillMaxWidth(),
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    text = "This can be a Mac, Linux, or cloud-hosted Haven relay. Leave blank to skip.",
                    color = TertiaryText,
                    fontSize = 11.sp,
                )
            }
        }

        Spacer(Modifier.height(20.dp))

        // Add relay input
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth(),
        ) {
            OutlinedTextField(
                value = newRelayInput,
                onValueChange = viewModel::setNewRelayInput,
                placeholder = { Text("wss://relay.example.com", color = TertiaryText) },
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = {
                    viewModel.addWizardRelay()
                    focusManager.clearFocus()
                }),
                colors = wizardTextFieldColors(),
                shape = RoundedCornerShape(8.dp),
                modifier = Modifier.weight(1f),
            )
            Spacer(Modifier.width(8.dp))
            IconButton(
                onClick = viewModel::addWizardRelay,
                enabled = newRelayInput.isNotBlank(),
            ) {
                Icon(
                    imageVector = NostrVaultIcons.Create,
                    contentDescription = "Add",
                    tint = if (newRelayInput.isNotBlank()) WizardAccent else TertiaryText,
                )
            }
        }

        Spacer(Modifier.height(12.dp))

        // Relay list
        WizardCard {
            if (relays.isEmpty()) {
                Text(
                    text = "No relays configured",
                    color = SecondaryText,
                    fontSize = 14.sp,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp),
                )
            } else {
                for ((index, relay) in relays.withIndex()) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 6.dp),
                    ) {
                        Icon(
                            imageVector = NostrVaultIcons.Domain,
                            contentDescription = null,
                            tint = WizardAccent,
                            modifier = Modifier.size(18.dp),
                        )
                        Spacer(Modifier.width(10.dp))
                        Text(
                            text = relay.removePrefix("wss://"),
                            color = PrimaryText,
                            fontSize = 14.sp,
                            modifier = Modifier.weight(1f),
                        )
                        IconButton(
                            onClick = { viewModel.removeWizardRelay(relay) },
                            modifier = Modifier.size(32.dp),
                        ) {
                            Icon(
                                imageVector = NostrVaultIcons.Dismiss,
                                contentDescription = "Remove",
                                tint = ErrorRed,
                                modifier = Modifier.size(16.dp),
                            )
                        }
                    }
                    if (index < relays.lastIndex) {
                        HorizontalDivider(
                            color = WizardBorderSubtle,
                            thickness = 0.5.dp,
                            modifier = Modifier.padding(start = 28.dp),
                        )
                    }
                }
            }
        }

        Spacer(Modifier.height(32.dp))
        WizardPrimaryButton(text = "Continue", onClick = viewModel::advanceFromRelays)
    }
}
