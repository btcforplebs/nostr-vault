package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.QrCodeScanner
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import com.nostrvault.setup.IdentityInput
import com.nostrvault.ui.components.NostrConnectPairing
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.launch

@Composable
internal fun AddAccountSection(viewModel: AccountSettingsViewModel) {
    val colors = LocalNostrVaultColors.current
    var expanded by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    var keyInput by remember { mutableStateOf("") }
    var keyPassword by remember { mutableStateOf("") }
    var bunkerInput by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    val addInput = IdentityInput.parse(keyInput)
    val needsPassword = addInput is IdentityInput.EncryptedSecretKey

    // Remote signers hand out their bunker string as a QR code. Typing one by
    // hand on a phone is the difference between the feature being usable and
    // being theoretical, and the app already scans QR codes in setup and the
    // wallet.
    val bunkerScanner = rememberLauncherForActivityResult(ScanContract()) { result ->
        result.contents?.trim()?.let { scanned ->
            if (scanned.startsWith("bunker://")) {
                bunkerInput = scanned
                error = null
            } else {
                error = "That QR code is not a bunker:// connection string"
            }
        }
    }

    if (!expanded) {
        OutlinedButton(onClick = { expanded = true }, modifier = Modifier.fillMaxWidth()) {
            Text("Add Account")
        }
        return
    }

    Text("Add Account", color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
    Spacer(Modifier.height(8.dp))
    OutlinedTextField(
        value = keyInput,
        onValueChange = { keyInput = it; error = null },
        placeholder = { Text("npub1…, nsec1… or ncryptsec1…") },
        singleLine = true,
        modifier = Modifier.fillMaxWidth(),
        colors = OutlinedTextFieldDefaults.colors(
            focusedTextColor = PrimaryText, unfocusedTextColor = PrimaryText,
            cursorColor = colors.primary, focusedBorderColor = colors.primary,
        ),
    )
    if (needsPassword) {
        // A NIP-49 key opens with the password it was made with.
        OutlinedTextField(
            value = keyPassword,
            onValueChange = { keyPassword = it; error = null },
            placeholder = { Text("Password for this key") },
            visualTransformation = PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
            singleLine = true,
            modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            colors = OutlinedTextFieldDefaults.colors(
                focusedTextColor = PrimaryText, unfocusedTextColor = PrimaryText,
                cursorColor = colors.primary, focusedBorderColor = colors.primary,
            ),
        )
    }
    Row(modifier = Modifier.padding(top = 8.dp)) {
        Button(
            onClick = {
                when (addInput) {
                    is IdentityInput.SecretKey -> {
                        if (viewModel.importKey(addInput.key) == null) error = "Invalid nsec"
                        else { keyInput = ""; expanded = false }
                    }
                    is IdentityInput.EncryptedSecretKey -> scope.launch {
                        if (viewModel.importEncryptedKey(addInput.key, keyPassword) == null) {
                            error = "That password didn't unlock the key."
                        } else { keyInput = ""; keyPassword = ""; expanded = false }
                    }
                    is IdentityInput.PublicKey -> { viewModel.addViewOnly(addInput.key); keyInput = ""; expanded = false }
                    else -> error = addAccountProblem(addInput)
                }
            },
            enabled = keyInput.isNotBlank() && (!needsPassword || keyPassword.isNotEmpty()),
            colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
        ) { Text("Add") }
        Spacer(Modifier.width(8.dp))
        TextButton(onClick = { expanded = false }) { Text("Cancel") }
    }

    Spacer(Modifier.height(12.dp))
    Text("Connect Remote Signer (NIP-46)", color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
    Spacer(Modifier.height(8.dp))
    NostrConnectPairing(
        accent = colors.primary,
        onPaired = { request, signerPubkey ->
            if (viewModel.pairNostrConnect(request, signerPubkey) == null) {
                "Could not connect signer"
            } else {
                expanded = false
                null
            }
        },
    )
    Spacer(Modifier.height(12.dp))
    Text("Or paste a bunker link from any signer app.", color = SecondaryText, fontSize = 12.sp)
    Spacer(Modifier.height(8.dp))
    OutlinedTextField(
        value = bunkerInput,
        onValueChange = { bunkerInput = it; error = null },
        placeholder = { Text("bunker://…") },
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
                    tint = colors.primary,
                )
            }
        },
        modifier = Modifier.fillMaxWidth(),
        colors = OutlinedTextFieldDefaults.colors(
            focusedTextColor = PrimaryText, unfocusedTextColor = PrimaryText,
            cursorColor = colors.primary, focusedBorderColor = colors.primary,
        ),
    )
    Button(
        onClick = {
            viewModel.connectSigner(bunkerInput.trim()) { result ->
                if (result == null) error = "Could not connect signer"
                else { bunkerInput = ""; expanded = false }
            }
        },
        enabled = bunkerInput.startsWith("bunker://"),
        colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
        modifier = Modifier.padding(top = 8.dp),
    ) { Text("Connect") }

    error?.let {
        Spacer(Modifier.height(8.dp))
        Text(it, color = ErrorRed, fontSize = 12.sp)
    }
}

/** Why Add Account can't take [input]: iOS AddAccountSheetView's "Must be an npub", widened to keys. */
internal fun addAccountProblem(input: IdentityInput): String? = when (input) {
    is IdentityInput.PublicKey, is IdentityInput.SecretKey, is IdentityInput.EncryptedSecretKey -> null
    is IdentityInput.HexKey -> "Paste the npub or nsec version of this key."
    else -> "Enter an npub, nsec or ncryptsec."
}
