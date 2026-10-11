package com.nostrvault.ui.screens

import androidx.compose.animation.*
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.foundation.layout.*
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

// ══════════════════════════════════════════════════════════════════
// Step 7: Wallet Setup
// ══════════════════════════════════════════════════════════════════

@Composable
internal fun WalletSetupStep(viewModel: SetupWizardViewModel) {
    val nwcInput by viewModel.nwcInput.collectAsState()
    val focusManager = LocalFocusManager.current

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            text = "Wallet Setup",
            color = PrimaryText,
            fontSize = 20.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = "Connect a Lightning wallet to send and receive zaps. Optional.",
            color = SecondaryText,
            fontSize = 14.sp,
            textAlign = TextAlign.Center,
        )

        Spacer(Modifier.height(20.dp))

        // NWC section
        WizardCard {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    imageVector = NostrVaultIcons.Zap,
                    contentDescription = null,
                    tint = WizardAccent,
                    modifier = Modifier.size(20.dp),
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    text = "Lightning (NWC)",
                    color = PrimaryText,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            }
            Spacer(Modifier.height(12.dp))
            OutlinedTextField(
                value = nwcInput,
                onValueChange = viewModel::setNwcInput,
                placeholder = { Text("nostr+walletconnect://...", color = TertiaryText) },
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { focusManager.clearFocus() }),
                colors = wizardTextFieldColors(),
                modifier = Modifier.fillMaxWidth(),
            )
        }

        Spacer(Modifier.height(16.dp))

        Spacer(Modifier.height(32.dp))

        if (nwcInput.isNotBlank()) {
            WizardPrimaryButton(text = "Save & Continue", onClick = viewModel::advanceFromWallet)
        } else {
            WizardSecondaryButton(text = "Skip", onClick = viewModel::skipWallet)
        }
    }
}
