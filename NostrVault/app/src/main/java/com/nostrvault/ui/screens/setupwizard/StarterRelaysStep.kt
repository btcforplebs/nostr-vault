package com.nostrvault.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.nostrvault.relay.RelayMatrix
import com.nostrvault.ui.screens.settings.RelayMatrixScreen
import com.nostrvault.ui.theme.*

/**
 * Create an account: the servers the new account's posts go through, and the
 * media servers its photos and videos go to, shown before anything is
 * published. Continue goes on; Change opens the Relays screen, whose Save is
 * what changes the relay list. The media servers are only this device's upload
 * servers until Save in Media servers publishes them.
 */
@Composable
internal fun StarterRelaysStep(viewModel: SetupWizardViewModel) {
    val cfg by viewModel.configStore.config.collectAsState()
    val relays = StarterRelays.from(cfg.activeFeedRelays)
    var changing by remember { mutableStateOf(false) }

    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
        Text(
            "Your posts will be shared through these servers",
            color = PrimaryText, fontSize = 20.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(20.dp))
        WizardCard {
            relays.forEach { url ->
                Text(
                    RelayMatrix.label(url), color = PrimaryText, fontSize = 15.sp, maxLines = 1,
                    overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(vertical = 6.dp),
                )
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
        WizardPrimaryButton(text = "Continue", onClick = viewModel::continueFromStarterRelays)
        Spacer(Modifier.height(4.dp))
        TextButton(onClick = { changing = true }) {
            Text("Change", color = SecondaryText, fontSize = 14.sp)
        }
    }

    if (changing) {
        Dialog(
            onDismissRequest = { changing = false },
            properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
        ) {
            RelayMatrixScreen(
                onBack = { changing = false },
                onOpenMediaServers = {},
                onSaved = { published -> viewModel.noteStarterRelaysSaved(published) },
            )
        }
    }
}
