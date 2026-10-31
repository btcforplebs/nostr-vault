package com.nostrvault.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.text.KeyboardOptions
import com.nostrvault.relay.RelayMatrix
import com.nostrvault.ui.theme.*

/**
 * Create an account: the starter relay list, shown before it is published.
 * Use publishes it when setup finishes, Edit changes it first, Skip
 * publishes nothing.
 */
@Composable
internal fun StarterRelaysStep(viewModel: SetupWizardViewModel) {
    LaunchedEffect(Unit) { viewModel.prepareStarterRelays() }
    val relays by viewModel.starterRelays.collectAsState()
    var editing by remember { mutableStateOf(false) }
    var typed by remember { mutableStateOf("") }
    var typedError by remember { mutableStateOf(false) }

    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
        Text("Your Relay List", color = PrimaryText, fontSize = 24.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(8.dp))
        Text(
            "Other Nostr apps read this list to find your posts. Here's a starter list. " +
                "Use it, edit it first, or skip: skipping publishes nothing. You can change it later in Settings > Relays.",
            color = SecondaryText, fontSize = 15.sp, lineHeight = 22.sp, textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(20.dp))

        WizardCard {
            if (relays.isEmpty()) {
                Text("No relays. Add one, or skip.", color = SecondaryText, fontSize = 14.sp)
            }
            relays.forEach { url ->
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().heightIn(min = 40.dp)) {
                    Text(RelayMatrix.label(url), color = PrimaryText, fontSize = 15.sp, maxLines = 1,
                        overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                    if (editing) {
                        Box(
                            contentAlignment = Alignment.Center,
                            modifier = Modifier.size(40.dp).clickable { viewModel.removeStarterRelay(url) }
                                .semantics { contentDescription = "Remove ${RelayMatrix.label(url)}" },
                        ) {
                            Box(contentAlignment = Alignment.Center, modifier = Modifier.size(22.dp).background(ErrorRed, CircleShape)) {
                                Box(Modifier.width(10.dp).height(2.dp).background(Color.White))
                            }
                        }
                    }
                }
            }
            if (editing) {
                Spacer(Modifier.height(12.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    OutlinedTextField(
                        value = typed,
                        onValueChange = { typed = it; typedError = false },
                        placeholder = { Text("relay.example.com") },
                        singleLine = true,
                        isError = typedError,
                        colors = wizardTextFieldColors(),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Done),
                        modifier = Modifier.weight(1f),
                    )
                    TextButton(
                        enabled = typed.isNotBlank(),
                        onClick = {
                            if (viewModel.addStarterRelay(typed)) typed = "" else typedError = true
                        },
                    ) { Text("Add", color = WizardAccent) }
                }
                if (typedError) {
                    Text("That isn't a public wss:// relay.", color = ErrorRed, fontSize = 12.sp)
                }
            }
        }

        Spacer(Modifier.height(24.dp))
        WizardPrimaryButton(
            text = if (editing) "Use This Edited List" else "Use This List",
            enabled = relays.isNotEmpty(),
            onClick = viewModel::useStarterRelays,
        )
        Spacer(Modifier.height(4.dp))
        WizardSecondaryButton(text = if (editing) "Done Editing" else "Edit", onClick = { editing = !editing })
        TextButton(onClick = viewModel::skipStarterRelays) {
            Text("Skip, Publish Nothing", color = SecondaryText, fontSize = 14.sp)
        }
    }
}
