package com.nostrvault.ui.screens.settings

import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import com.nostrvault.data.local.CredentialStore
import com.nostrvault.relay.HavenConfig
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.delay
import java.security.MessageDigest

@Composable
internal fun AccountDetail(
    npub: String,
    cfg: HavenConfig,
    isOwner: Boolean,
    isActive: Boolean,
    hasLocalKey: Boolean,
    viewModel: AccountSettingsViewModel,
) {
    val context = LocalContext.current
    val colors = LocalNostrVaultColors.current
    val hasBunker = cfg.bunkerConfig(npub) != null
    var revealed by remember(npub) { mutableStateOf<String?>(null) }
    var revealError by remember(npub) { mutableStateOf<String?>(null) }
    var askRevealPassword by remember(npub) { mutableStateOf(false) }
    var confirmRemoveKey by remember(npub) { mutableStateOf(false) }
    var confirmDisconnectSigner by remember(npub) { mutableStateOf(false) }
    var confirmRemoveAccount by remember(npub) { mutableStateOf(false) }
    var importingKey by remember(npub) { mutableStateOf(false) }
    var connectingSigner by remember(npub) { mutableStateOf(false) }

    if (connectingSigner) {
        ConnectSignerSheet(
            npub = npub,
            viewModel = viewModel,
            onDismiss = { connectingSigner = false },
        )
    }

    if (importingKey) {
        ImportKeyDialog(
            npub = npub,
            isOwner = isOwner,
            viewModel = viewModel,
            onDismiss = { importingKey = false },
        )
    }

    if (askRevealPassword) {
        RevealKeyPasswordDialog(
            onUnlock = { typed ->
                val problem = revealKeyPasswordProblem(CredentialStore.getKeychainPassword(npub), typed)
                if (problem == null) {
                    askRevealPassword = false
                    revealed = viewModel.revealNsec(npub)
                }
                problem
            },
            onDismiss = { askRevealPassword = false },
        )
    }

    // Same titles, messages and buttons as iOS (AccountDetailView.swift).
    if (confirmDisconnectSigner) {
        AlertDialog(
            onDismissRequest = { confirmDisconnectSigner = false },
            title = { Text("Disconnect Remote Signer") },
            text = {
                Text(
                    if (hasLocalKey) {
                        "This drops the remote signer connection and its stored session. Signing falls back to the local key on this device; reconnecting needs a fresh bunker URI."
                    } else {
                        "This drops the remote signer connection and its stored session, and nothing else here can sign for this account afterwards. Reconnecting needs a fresh bunker URI."
                    },
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmDisconnectSigner = false
                    viewModel.disconnectSigner(npub)
                }) { Text("Disconnect", color = ErrorRed) }
            },
            dismissButton = {
                TextButton(onClick = { confirmDisconnectSigner = false }) { Text("Cancel") }
            },
        )
    }

    if (confirmRemoveAccount) {
        AlertDialog(
            onDismissRequest = { confirmRemoveAccount = false },
            title = { Text("Remove Account") },
            text = {
                Text("This removes ${npub.take(12)}… from Nostr Vault, along with any key or signer stored for it. Nothing on the relays changes, but you will need the key again to sign back in.")
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmRemoveAccount = false
                    viewModel.removeAccount(npub)
                }) { Text("Remove Account", color = ErrorRed) }
            },
            dismissButton = {
                TextButton(onClick = { confirmRemoveAccount = false }) { Text("Cancel") }
            },
        )
    }

    if (confirmRemoveKey) {
        AlertDialog(
            onDismissRequest = { confirmRemoveKey = false },
            title = { Text("Remove Local Key") },
            text = {
                Text(
                    if (hasBunker) {
                        "This deletes the private key stored on this device. Signing falls back to the remote signer. If you have no backup of the key elsewhere, it cannot be recovered."
                    } else {
                        "This deletes the private key stored on this device, and nothing else here can sign for this account afterwards. If you have no backup of the key elsewhere, it cannot be recovered."
                    },
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmRemoveKey = false
                    revealed = null
                    viewModel.removeLocalKey(npub)
                }) { Text("Remove Key", color = ErrorRed) }
            },
            dismissButton = {
                TextButton(onClick = { confirmRemoveKey = false }) { Text("Cancel") }
            },
        )
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 52.dp, bottom = 8.dp),
    ) {
        if (!isActive) {
            TextButton(onClick = { viewModel.switchTo(npub) }) {
                Text("Switch to this account", color = colors.primary)
            }
        }

        // Signing-method picker when both local key and bunker exist.
        if (hasLocalKey && hasBunker) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = 4.dp)) {
                Text("Signing", color = SecondaryText, fontSize = 13.sp)
                InfoButton(SettingsHelp.ACCOUNT_SIGNING)
                Spacer(Modifier.weight(1f))
                FilterChip(
                    selected = cfg.signingMode(npub) == "local",
                    onClick = { viewModel.setSigningMode(npub, "local") },
                    label = { Text("Local") },
                )
                Spacer(Modifier.width(6.dp))
                FilterChip(
                    selected = cfg.signingMode(npub) == "nip46",
                    onClick = { viewModel.setSigningMode(npub, "nip46") },
                    label = { Text("Remote") },
                )
            }
        }

        // Local key. Same gate as iOS: device-owner auth first (fail closed),
        // then the NIP-49 password when the account has one (RevealKeySheetView).
        if (hasLocalKey) {
            if (revealed == null) {
                TextButton(onClick = {
                    revealError = null
                    val activity = context as? FragmentActivity
                    if (activity == null) {
                        revealError = REVEAL_AUTH_UNAVAILABLE
                    } else {
                        authenticateToReveal(
                            activity,
                            onSuccess = {
                                if (CredentialStore.getKeychainPassword(npub) != null) {
                                    askRevealPassword = true
                                } else {
                                    val nsec = viewModel.revealNsec(npub)
                                    if (nsec == null) revealError = REVEAL_NO_KEY else revealed = nsec
                                }
                            },
                            onError = { revealError = it },
                        )
                    }
                }) {
                    Text("Reveal Private Key", color = colors.primary)
                    InfoButton(SettingsHelp.ACCOUNT_REVEAL_KEY)
                }
                revealError?.let { Text(it, color = ErrorRed, fontSize = 12.sp, modifier = Modifier.padding(bottom = 4.dp)) }
            } else {
                RevealedKey(nsec = revealed!!, onHide = { revealed = null })
            }
            TextButton(onClick = { confirmRemoveKey = true }) {
                Text("Remove Local Key", color = ErrorRed)
            }
        } else {
            TextButton(onClick = { importingKey = true }) {
                Text("Import Private Key", color = colors.primary)
            }
        }

        // Remote signer: pair one, or drop the one there (iOS AccountDetailView's
        // Remote Signer section).
        if (hasBunker) {
            TextButton(onClick = { confirmDisconnectSigner = true }) {
                Text("Disconnect Remote Signer", color = ErrorRed)
            }
        } else {
            TextButton(onClick = { connectingSigner = true }) {
                Text("Connect Remote Signer", color = colors.primary)
            }
        }

        // NIP-65 publish toggle
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = 4.dp)) {
            Text("Publish Relay List (NIP-65)", color = PrimaryText, fontSize = 13.sp)
            InfoButton(SettingsHelp.ACCOUNT_PUBLISH_INBOX)
            Spacer(Modifier.weight(1f))
            Switch(
                checked = cfg.publishRelayListPerAccount[npub] ?: false,
                onCheckedChange = { viewModel.togglePublishRelayList(npub, it) },
                colors = SwitchDefaults.colors(checkedThumbColor = PrimaryText, checkedTrackColor = colors.primary),
            )
        }

        if (!isOwner) {
            TextButton(onClick = { confirmRemoveAccount = true }) {
                Text("Remove Account", color = ErrorRed)
            }
        }
    }
}

/** The revealed nsec with Copy (shows Copied for two seconds), Hide, and the iOS warning line. */
@Composable
private fun RevealedKey(nsec: String, onHide: () -> Unit) {
    val clipboard = LocalClipboardManager.current
    var copied by remember(nsec) { mutableStateOf(false) }
    LaunchedEffect(copied) {
        if (copied) {
            delay(2_000)
            copied = false
        }
    }
    Column(modifier = Modifier.padding(vertical = 4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                nsec,
                color = PrimaryText,
                fontSize = 12.sp,
                fontFamily = FontFamily.Monospace,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            IconButton(onClick = {
                clipboard.setText(AnnotatedString(nsec))
                copied = true
            }) {
                Icon(
                    if (copied) Icons.Filled.Check else NostrVaultIcons.Copy,
                    contentDescription = if (copied) "Copied" else "Copy",
                    tint = if (copied) ZapOrange else SecondaryText,
                    modifier = Modifier.size(16.dp),
                )
            }
            IconButton(onClick = onHide) {
                Icon(NostrVaultIcons.Dismiss, contentDescription = "Hide", tint = SecondaryText, modifier = Modifier.size(16.dp))
            }
        }
        Text(
            if (copied) "Copied!" else REVEAL_KEY_WARNING,
            color = ZapOrange,
            fontSize = 11.sp,
            modifier = Modifier.padding(end = 8.dp),
        )
    }
}

/**
 * Second step of Reveal Private Key, as iOS RevealKeySheetView: the NIP-49
 * password the key is stored with. [onUnlock] returns an error message to show,
 * or null when the key was revealed (the caller closes the dialog).
 */
@Composable
private fun RevealKeyPasswordDialog(onUnlock: (String) -> String?, onDismiss: () -> Unit) {
    val colors = LocalNostrVaultColors.current
    var password by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Reveal Private Key") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Enter Password", color = SecondaryText, fontSize = 13.sp)
                OutlinedTextField(
                    value = password,
                    onValueChange = { password = it; error = null },
                    placeholder = { Text("NIP-49 Password") },
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedTextColor = PrimaryText, unfocusedTextColor = PrimaryText,
                        cursorColor = colors.primary, focusedBorderColor = colors.primary,
                    ),
                )
                error?.let { Text(it, color = ErrorRed, fontSize = 12.sp) }
            }
        },
        confirmButton = {
            TextButton(
                onClick = { error = onUnlock(password) },
                enabled = password.isNotEmpty(),
            ) { Text("Unlock") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}

/**
 * Prompt biometric or device-credential auth and run [onSuccess] only on
 * success. Fails closed: when nothing is enrolled, the prompt errors, or the
 * user backs out, the key stays hidden. [onError] gets a message for the
 * cases the user has to act on; a plain cancel shows nothing.
 */
private fun authenticateToReveal(activity: FragmentActivity, onSuccess: () -> Unit, onError: (String) -> Unit) {
    val authenticators = BiometricManager.Authenticators.BIOMETRIC_STRONG or
        BiometricManager.Authenticators.DEVICE_CREDENTIAL
    if (BiometricManager.from(activity).canAuthenticate(authenticators) != BiometricManager.BIOMETRIC_SUCCESS) {
        onError(REVEAL_NEEDS_SCREEN_LOCK)
        return
    }
    val executor = ContextCompat.getMainExecutor(activity)
    val prompt = BiometricPrompt(
        activity,
        executor,
        object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                onSuccess()
            }

            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                when (errorCode) {
                    BiometricPrompt.ERROR_USER_CANCELED,
                    BiometricPrompt.ERROR_NEGATIVE_BUTTON,
                    BiometricPrompt.ERROR_CANCELED -> Unit
                    else -> onError("Authentication failed: $errString")
                }
            }
        },
    )
    val info = BiometricPrompt.PromptInfo.Builder()
        .setTitle("Authenticate")
        .setSubtitle("Reveal your private key")
        .setAllowedAuthenticators(authenticators)
        .build()
    prompt.authenticate(info)
}

internal const val REVEAL_AUTH_UNAVAILABLE = "Authentication isn't available here, so the key stays hidden."
internal const val REVEAL_NEEDS_SCREEN_LOCK = "Set a screen lock or fingerprint on this device to reveal your private key."
internal const val REVEAL_NO_KEY = "No encrypted key found for this account"
internal const val REVEAL_WRONG_PASSWORD = "Incorrect password or decryption failed"
internal const val REVEAL_KEY_WARNING = "Keep this key safe. Anyone with your nsec has full control of your Nostr identity."

/**
 * Reveal Private Key's password gate, with iOS RevealKeySheetView's messages:
 * [stored] is the NIP-49 password the key was saved with (null when the
 * account has none on record), [typed] is what the user entered. Returns the
 * error to show, or null when the key may be revealed.
 */
internal fun revealKeyPasswordProblem(stored: String?, typed: String): String? = when {
    stored == null -> REVEAL_NO_KEY
    typed.isEmpty() -> REVEAL_WRONG_PASSWORD
    !MessageDigest.isEqual(stored.toByteArray(), typed.toByteArray()) -> REVEAL_WRONG_PASSWORD
    else -> null
}
