package com.nostrvault.ui.screens.settings

import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import com.nostrvault.relay.HavenConfig
import com.nostrvault.ui.theme.*

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
    val clipboard = LocalClipboardManager.current
    val colors = LocalNostrVaultColors.current
    val hasBunker = cfg.bunkerConfig(npub) != null
    var revealed by remember(npub) { mutableStateOf<String?>(null) }
    var confirmRemoveKey by remember(npub) { mutableStateOf(false) }
    var confirmDisconnectSigner by remember(npub) { mutableStateOf(false) }
    var confirmRemoveAccount by remember(npub) { mutableStateOf(false) }
    var importingKey by remember(npub) { mutableStateOf(false) }

    if (importingKey) {
        ImportKeyDialog(
            npub = npub,
            isOwner = isOwner,
            viewModel = viewModel,
            onDismiss = { importingKey = false },
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

        // Local key
        if (hasLocalKey) {
            if (revealed == null) {
                TextButton(onClick = {
                    val activity = context as? FragmentActivity
                    if (activity != null) {
                        authenticateAndReveal(activity) { revealed = viewModel.revealNsec(npub) }
                    } else {
                        revealed = viewModel.revealNsec(npub)
                    }
                }) {
                    Text("Reveal Private Key", color = colors.primary)
                    InfoButton(SettingsHelp.ACCOUNT_REVEAL_KEY)
                }
            } else {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = 4.dp)) {
                    Text(
                        revealed!!,
                        color = PrimaryText,
                        fontSize = 12.sp,
                        fontFamily = FontFamily.Monospace,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                    IconButton(onClick = { clipboard.setText(AnnotatedString(revealed!!)) }) {
                        Icon(NostrVaultIcons.Copy, contentDescription = "Copy", tint = SecondaryText, modifier = Modifier.size(16.dp))
                    }
                    IconButton(onClick = { revealed = null }) {
                        Icon(NostrVaultIcons.Dismiss, contentDescription = "Hide", tint = SecondaryText, modifier = Modifier.size(16.dp))
                    }
                }
            }
            TextButton(onClick = { confirmRemoveKey = true }) {
                Text("Remove Local Key", color = ErrorRed)
            }
        } else {
            TextButton(onClick = { importingKey = true }) {
                Text("Import Private Key", color = colors.primary)
            }
        }

        // Remote signer
        if (hasBunker) {
            TextButton(onClick = { confirmDisconnectSigner = true }) {
                Text("Disconnect Remote Signer", color = ErrorRed)
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

/** Prompt biometric/device-credential auth, then run [onSuccess] on success. */
private fun authenticateAndReveal(activity: FragmentActivity, onSuccess: () -> Unit) {
    val executor = ContextCompat.getMainExecutor(activity)
    val prompt = BiometricPrompt(
        activity,
        executor,
        object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                onSuccess()
            }
        },
    )
    val info = BiometricPrompt.PromptInfo.Builder()
        .setTitle("Authenticate")
        .setSubtitle("Reveal your private key")
        .setAllowedAuthenticators(
            BiometricManager.Authenticators.BIOMETRIC_STRONG or
                BiometricManager.Authenticators.DEVICE_CREDENTIAL,
        )
        .build()
    prompt.authenticate(info)
}
