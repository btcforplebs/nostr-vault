package com.nostrvault.ui.screens

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.compose.animation.*
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import com.nostrvault.ui.components.NostrConnectPairing
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.launch

// ══════════════════════════════════════════════════════════════════
// Step 3: Account
// ══════════════════════════════════════════════════════════════════

@Composable
internal fun AccountStep(viewModel: SetupWizardViewModel) {
    val setupPath by viewModel.setupPath.collectAsState()
    val mode by viewModel.accountMode.collectAsState()
    val npubInput by viewModel.npubInput.collectAsState()
    val nsecInput by viewModel.nsecInput.collectAsState()
    val error by viewModel.error.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val generatedNsec by viewModel.generatedNsec.collectAsState()
    val isAmberAvailable by viewModel.isAmberAvailable.collectAsState()
    val focusManager = LocalFocusManager.current

    val bunkerInput by viewModel.bunkerInput.collectAsState()

    // A bunker string is long and arrives as a QR code from the signer;
    // scanning it is the difference between the option being usable and being
    // theoretical.
    val bunkerScanner = rememberLauncherForActivityResult(ScanContract()) { result ->
        result.contents?.trim()?.let { viewModel.setBunkerInput(it) }
    }

    // QR scanner launcher
    val qrLauncher = rememberLauncherForActivityResult(ScanContract()) { result ->
        result.contents?.let { scanned ->
            val cleaned = if (scanned.startsWith("nostr:")) scanned.removePrefix("nostr:") else scanned
            viewModel.setNpubInput(cleaned)
        }
    }

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            text = if (setupPath == SetupPath.BROWSE) "Enter your identity" else "Set up your account",
            color = PrimaryText,
            fontSize = 20.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(20.dp))

        if (setupPath == SetupPath.BROWSE) {
            // Browse mode: npub, NIP-05, or QR
            Text(
                text = "Enter your npub, NIP-05 (user@domain), or scan a QR code.",
                color = SecondaryText,
                fontSize = 14.sp,
                lineHeight = 20.sp,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(16.dp))
            OutlinedTextField(
                value = npubInput,
                onValueChange = viewModel::setNpubInput,
                label = { Text("npub1... or user@domain.com") },
                isError = error != null,
                supportingText = error?.let { { Text(it, color = ErrorRed) } },
                singleLine = true,
                trailingIcon = {
                    IconButton(onClick = {
                        qrLauncher.launch(
                            ScanOptions().apply {
                                setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                                setPrompt("Scan a Nostr QR code")
                                setBeepEnabled(false)
                                setOrientationLocked(true)
                            }
                        )
                    }) {
                        Icon(
                            Icons.Default.QrCodeScanner,
                            contentDescription = "Scan QR code",
                            tint = WizardAccent,
                        )
                    }
                },
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { focusManager.clearFocus() }),
                colors = wizardTextFieldColors(),
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(24.dp))
            WizardPrimaryButton(
                text = if (npubInput.contains("@") || (!npubInput.startsWith("npub") && npubInput.contains(".")))
                    "Resolve & Continue" else "Continue",
                enabled = !isLoading && npubInput.isNotBlank(),
                isLoading = isLoading,
                onClick = viewModel::advanceFromAccount,
            )
        } else {
            // Full mode: Generate / Import / Amber
            Row(
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                WizardOptionCard(
                    title = "Generate New",
                    subtitle = "Create a new Nostr identity",
                    selected = mode == AccountMode.GENERATE,
                    onClick = { viewModel.setAccountMode(AccountMode.GENERATE) },
                    modifier = Modifier.weight(1f),
                )
                WizardOptionCard(
                    title = "Import Key",
                    subtitle = "Use an existing nsec",
                    selected = mode == AccountMode.IMPORT,
                    onClick = { viewModel.setAccountMode(AccountMode.IMPORT) },
                    modifier = Modifier.weight(1f),
                )
            }

            if (isAmberAvailable) {
                Spacer(Modifier.height(12.dp))
                WizardOptionCard(
                    title = "Use Amber Signer",
                    subtitle = "Sign events with the Amber app (NIP-55)",
                    selected = mode == AccountMode.AMBER,
                    onClick = { viewModel.setAccountMode(AccountMode.AMBER) },
                    modifier = Modifier.fillMaxWidth(),
                )
            }

            Spacer(Modifier.height(12.dp))
            WizardOptionCard(
                title = "Connect Remote Signer",
                subtitle = "Any NIP-46 signer — nsec.app, a bunker, your own",
                selected = mode == AccountMode.REMOTE_SIGNER,
                onClick = { viewModel.setAccountMode(AccountMode.REMOTE_SIGNER) },
                modifier = Modifier.fillMaxWidth(),
            )

            Spacer(Modifier.height(24.dp))

            AnimatedVisibility(visible = mode == AccountMode.IMPORT) {
                Column {
                    OutlinedTextField(
                        value = nsecInput,
                        onValueChange = viewModel::setNsecInput,
                        label = { Text("nsec1...") },
                        visualTransformation = PasswordVisualTransformation(),
                        isError = error != null,
                        supportingText = error?.let { { Text(it, color = ErrorRed) } },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                        keyboardActions = KeyboardActions(onDone = { focusManager.clearFocus() }),
                        colors = wizardTextFieldColors(),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Spacer(Modifier.height(16.dp))
                }
            }

            AnimatedVisibility(visible = mode == AccountMode.REMOTE_SIGNER) {
                Column {
                    NostrConnectPairing(
                        accent = WizardAccent,
                        onPaired = { request, signerPubkey -> viewModel.pairNostrConnect(request, signerPubkey) },
                    )
                    Spacer(Modifier.height(16.dp))
                    Text(
                        text = "Or paste or scan the bunker:// string your signer gives you. Your key stays with the signer -- Nostr Vault never sees it.",
                        color = SecondaryText,
                        fontSize = 14.sp,
                        lineHeight = 20.sp,
                        textAlign = TextAlign.Center,
                    )
                    Spacer(Modifier.height(12.dp))
                    OutlinedTextField(
                        value = bunkerInput,
                        onValueChange = viewModel::setBunkerInput,
                        label = { Text("bunker://...") },
                        isError = error != null,
                        supportingText = error?.let { { Text(it, color = ErrorRed) } },
                        singleLine = true,
                        trailingIcon = {
                            IconButton(onClick = {
                                bunkerScanner.launch(
                                    ScanOptions().apply {
                                        setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                                        setPrompt("Scan your signer's bunker:// code")
                                        setBeepEnabled(false)
                                        setOrientationLocked(true)
                                    }
                                )
                            }) {
                                Icon(
                                    Icons.Default.QrCodeScanner,
                                    contentDescription = "Scan bunker QR code",
                                    tint = WizardAccent,
                                )
                            }
                        },
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                        keyboardActions = KeyboardActions(onDone = { focusManager.clearFocus() }),
                        colors = wizardTextFieldColors(),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Spacer(Modifier.height(16.dp))
                }
            }

            AnimatedVisibility(visible = mode == AccountMode.AMBER) {
                Column {
                    Text(
                        text = "Amber will handle all event signing. Your private key stays in Amber -- Nostr Vault never sees it.",
                        color = SecondaryText,
                        fontSize = 14.sp,
                        lineHeight = 20.sp,
                        textAlign = TextAlign.Center,
                    )
                    Spacer(Modifier.height(16.dp))
                }
            }

            error?.let { errorText ->
                if (mode != AccountMode.IMPORT) {
                    Text(errorText, color = ErrorRed, fontSize = 13.sp)
                    Spacer(Modifier.height(8.dp))
                }
            }

            WizardPrimaryButton(
                text = when (mode) {
                    AccountMode.GENERATE -> "Generate Keypair"
                    AccountMode.IMPORT -> "Import Key"
                    AccountMode.AMBER -> "Connect Amber"
                    AccountMode.REMOTE_SIGNER -> "Connect Signer"
                },
                enabled = !isLoading && when (mode) {
                    AccountMode.IMPORT -> nsecInput.isNotBlank()
                    AccountMode.REMOTE_SIGNER -> bunkerInput.trim().startsWith("bunker://")
                    else -> true
                },
                isLoading = isLoading,
                onClick = viewModel::advanceFromAccount,
            )
        }
    }
}
