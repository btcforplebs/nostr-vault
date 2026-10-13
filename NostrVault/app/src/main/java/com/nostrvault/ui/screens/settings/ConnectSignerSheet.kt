package com.nostrvault.ui.screens.settings

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import com.nostrvault.relay.AccountBunkerConfig
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.NIP46Service
import com.nostrvault.ui.components.NostrConnectPairing
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.launch

/**
 * Pairs a remote signer with an account that is already here (iOS
 * ConnectSignerSheetView), from the account's detail. Unlike Add Account,
 * the signer has to answer as this account's own key: one that answers as
 * any other key is refused and nothing is stored. Nothing is stored on a
 * failed connect either, so a cancelled or failed pairing leaves the account
 * signing (or browsing) exactly as it was.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ConnectSignerSheet(
    npub: String,
    viewModel: AccountSettingsViewModel,
    onDismiss: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    val scope = rememberCoroutineScope()
    var bunkerInput by remember { mutableStateOf("") }
    var connecting by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = Surface2) {
        Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(bottom = 32.dp)) {
            Text("Connect Remote Signer", color = PrimaryText, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            Text(
                "The signer must hold the key for ${npub.take(12)}…; one for another account is refused.",
                color = SecondaryText,
                fontSize = 12.sp,
                modifier = Modifier.padding(top = 4.dp, bottom = 12.dp),
            )
            NostrConnectPairing(
                accent = colors.primary,
                onPaired = { request, signerPubkey ->
                    val problem = viewModel.pairNostrConnectFor(npub, request, signerPubkey)
                    if (problem == null) onDismiss()
                    problem
                },
            )
            Spacer(Modifier.height(12.dp))
            Text("Or paste a bunker link from any signer app.", color = SecondaryText, fontSize = 12.sp)
            Spacer(Modifier.height(8.dp))
            BunkerLinkField(
                value = bunkerInput,
                onValueChange = { bunkerInput = it; error = null },
                onScanProblem = { error = it },
            )
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 8.dp)) {
                Button(
                    onClick = {
                        connecting = true
                        error = null
                        scope.launch {
                            val problem = viewModel.connectSignerFor(npub, bunkerInput.trim())
                            connecting = false
                            if (problem == null) onDismiss() else error = problem
                        }
                    },
                    enabled = bunkerInput.trim().startsWith("bunker://") && !connecting,
                    colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
                ) { Text("Connect") }
                Spacer(Modifier.width(8.dp))
                TextButton(onClick = onDismiss) { Text("Cancel") }
            }
            if (connecting) {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 8.dp)) {
                    CircularProgressIndicator(color = colors.primary, strokeWidth = 2.dp, modifier = Modifier.size(14.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("Approve the connection in your signer app", color = SecondaryText, fontSize = 12.sp)
                }
            }
            error?.let {
                Spacer(Modifier.height(8.dp))
                Text(it, color = ErrorRed, fontSize = 12.sp)
            }
        }
    }
}

/**
 * A bunker:// link field with the QR scanner Add Account and Connect Signer
 * share. Remote signers hand out their bunker string as a QR code; typing
 * one by hand on a phone is the difference between the feature being usable
 * and being theoretical. [onScanProblem] gets the message for a code that
 * isn't a bunker link.
 */
@Composable
internal fun BunkerLinkField(
    value: String,
    onValueChange: (String) -> Unit,
    onScanProblem: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalNostrVaultColors.current
    val scanner = rememberLauncherForActivityResult(ScanContract()) { result ->
        result.contents?.trim()?.let { scanned ->
            if (scanned.startsWith("bunker://")) onValueChange(scanned)
            else onScanProblem("That QR code is not a bunker:// connection string")
        }
    }
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        placeholder = { Text("bunker://…") },
        singleLine = true,
        trailingIcon = {
            IconButton(onClick = {
                scanner.launch(
                    ScanOptions().apply {
                        setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                        setPrompt("Scan your signer's bunker:// code")
                        setBeepEnabled(false)
                        setOrientationLocked(true)
                    }
                )
            }) {
                Icon(Icons.Default.QrCodeScanner, contentDescription = "Scan bunker QR code", tint = colors.primary)
            }
        },
        modifier = modifier.fillMaxWidth(),
        colors = OutlinedTextFieldDefaults.colors(
            focusedTextColor = PrimaryText, unfocusedTextColor = PrimaryText,
            cursorColor = colors.primary, focusedBorderColor = colors.primary,
        ),
    )
}

/**
 * The pairing itself, apart from the screen so it can be tested against a
 * fake signer. Connects first and stores only on success: a signer that
 * answers as another key, or not at all, leaves the account untouched.
 */
internal object SignerPairing {
    const val BAD_NPUB = "This account's npub can't be read."
    const val NOT_REACHED = "Could not connect this signer, or it signs for a different account."

    /** Where a successful pairing is written: the account's bunker config and its signing mode. */
    class Store(
        val setBunkerConfig: (npub: String, AccountBunkerConfig) -> Unit,
        val setSigningMode: (npub: String, mode: String) -> Unit,
    )

    /**
     * Pairs [npub] with the signer behind [bunkerUri] over the client key
     * [clientSecretKey] / [clientPubkey]. The active account's session is
     * made the live signer; any other account's is opened in the background
     * so the active account's signing is not disturbed. Returns the message
     * to show, or null when the signer is stored for the account.
     */
    suspend fun pair(
        npub: String,
        bunkerUri: String,
        clientSecretKey: String,
        clientPubkey: String,
        activeHexPubkey: String,
        store: Store,
    ): String? {
        val expected = HavenBridge.decodeNpub(npub) ?: return BAD_NPUB
        val cfg = AccountBunkerConfig(
            bunkerURI = bunkerUri,
            signerPubkey = expected,
            clientSecretKey = clientSecretKey,
            clientPubkey = clientPubkey,
        )
        val connected = if (expected == activeHexPubkey) {
            NIP46Service.connectForAccount(cfg, expected) != null
        } else {
            NIP46Service.connectInBackground(cfg, expected)
        }
        if (!connected) {
            // The active path says why (a signer answering as another key);
            // a background login only says no.
            return NIP46Service.lastError.value?.takeIf { expected == activeHexPubkey } ?: NOT_REACHED
        }
        store.setBunkerConfig(npub, cfg)
        store.setSigningMode(npub, "nip46")
        return null
    }
}
