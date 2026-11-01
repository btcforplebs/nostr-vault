package com.nostrvault.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.relay.RelayMatrix
import com.nostrvault.ui.theme.*

/**
 * Create an account: the new account has no relay list yet, so the
 * recommended servers are shown as suggestions. The owner can remove any,
 * add their own, or take the suggestions as they are with Use recommended.
 * Nothing is published here: Continue or Use recommended confirms the list,
 * and setup publishes it (kind 10002) when it finishes. The media servers
 * are only this device's upload servers until Save in Media servers
 * publishes them.
 */
@Composable
internal fun StarterRelaysStep(viewModel: SetupWizardViewModel) {
    val cfg by viewModel.configStore.config.collectAsState()
    val draft by viewModel.starterRelayDraft.collectAsState()
    val recommended = StarterRelays.from(cfg.activeFeedRelays)
    val relays = draft ?: recommended
    var input by remember { mutableStateOf("") }
    var invalid by remember { mutableStateOf(false) }

    fun add() {
        if (viewModel.addStarterRelay(input)) {
            input = ""
            invalid = false
        } else {
            invalid = true
        }
    }

    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
        Text(
            "Choose the servers your posts go through",
            color = PrimaryText, fontSize = 20.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(6.dp))
        Text(
            "Your new account has no server list yet. These are our suggestions. Remove any, or add your own.",
            color = SecondaryText, fontSize = 14.sp, textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(16.dp))
        WizardCard {
            if (relays.isEmpty()) {
                Text("No servers. Add one, or use the recommended ones.", color = SecondaryText, fontSize = 14.sp)
            }
            relays.forEach { url ->
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                    Text(
                        RelayMatrix.label(url), color = PrimaryText, fontSize = 15.sp, maxLines = 1,
                        overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f),
                    )
                    IconButton(onClick = { viewModel.removeStarterRelay(url) }, modifier = Modifier.size(36.dp)) {
                        Icon(
                            Icons.Filled.Close, contentDescription = "Remove ${RelayMatrix.label(url)}",
                            tint = SecondaryText, modifier = Modifier.size(18.dp),
                        )
                    }
                }
            }
            Spacer(Modifier.height(8.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(
                    value = input,
                    onValueChange = { input = it; invalid = false },
                    placeholder = { Text("relay.example.com") },
                    singleLine = true,
                    isError = invalid,
                    supportingText = if (invalid) {
                        { Text("Enter a wss:// server address") }
                    } else null,
                    colors = wizardTextFieldColors(),
                    keyboardOptions = KeyboardOptions(
                        keyboardType = KeyboardType.Uri, imeAction = ImeAction.Done, autoCorrectEnabled = false,
                    ),
                    keyboardActions = KeyboardActions(onDone = { add() }),
                    modifier = Modifier.weight(1f),
                )
                Spacer(Modifier.width(8.dp))
                TextButton(onClick = ::add, enabled = input.isNotBlank()) {
                    Text("Add", color = if (input.isNotBlank()) WizardAccent else SecondaryText, fontSize = 15.sp)
                }
            }
        }
        val media = cfg.blossomMirrors
        if (media.isNotEmpty()) {
            Spacer(Modifier.height(20.dp))
            Text(
                "Your photos and videos will be stored on these servers",
                color = PrimaryText, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(12.dp))
            WizardCard {
                media.forEach { url ->
                    Text(
                        url.removePrefix("https://").trimEnd('/'), color = PrimaryText, fontSize = 15.sp, maxLines = 1,
                        overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(vertical = 6.dp),
                    )
                }
            }
        }
        Spacer(Modifier.height(24.dp))
        WizardPrimaryButton(
            text = "Continue", enabled = relays.isNotEmpty(), onClick = viewModel::continueFromStarterRelays,
        )
        Spacer(Modifier.height(4.dp))
        WizardSecondaryButton(text = "Use recommended", onClick = viewModel::useRecommendedStarterRelays)
    }
}
