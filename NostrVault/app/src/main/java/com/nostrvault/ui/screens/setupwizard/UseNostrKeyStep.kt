package com.nostrvault.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import androidx.activity.compose.rememberLauncherForActivityResult
import com.nostrvault.setup.IdentityInput
import com.nostrvault.ui.components.NostrConnectPairing
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.SuccessGreen

// The "I already use Nostr" path: one key field, a relay check, then the
// import tour. Same as iOS UseNostrSteps.swift (design: Tory's mockup,
// ~/.buzz/OUTBOX/i-use-nostr-mockup.html).

internal val Muted = SecondaryText.copy(alpha = 0.6f)

// ══════════════════════════════════════════════════════════════════
// Your key
// ══════════════════════════════════════════════════════════════════

private enum class ModeTone { READ, POST, ERROR }
private data class ModeLine(val tone: ModeTone, val title: String, val detail: String)

/**
 * One field for whatever the person already has. What they paste decides the
 * mode ([IdentityInput]): an npub or name@domain is read-only, a private key
 * or a signer app can post. Replaces the Full Setup / Browse choice.
 */
@Composable
internal fun UseNostrKeyStep(viewModel: SetupWizardViewModel) {
    val raw by viewModel.useNostrInput.collectAsState()
    val password by viewModel.useNostrPassword.collectAsState()
    val confirm by viewModel.useNostrConfirm.collectAsState()
    val error by viewModel.error.collectAsState()
    val isWorking by viewModel.isLoading.collectAsState()
    val isAmberAvailable by viewModel.isAmberAvailable.collectAsState()
    val focusManager = LocalFocusManager.current
    var showingSigner by rememberSaveable { mutableStateOf(false) }
    var showPassword by remember { mutableStateOf(false) }

    val kind = remember(raw) { IdentityInput.parse(raw) }
    val checksumOK = remember(kind) { viewModel.keyChecksumOK(kind) }
    val line = modeLine(kind, checksumOK)
    val isUsable = line != null && line.tone != ModeTone.ERROR
    val needsPassword = (kind is IdentityInput.SecretKey && checksumOK) || kind is IdentityInput.EncryptedSecretKey
    val isNewPassword = kind is IdentityInput.SecretKey
    val passwordProblem = if (needsPassword) viewModel.useNostrPasswordProblem(kind) else null
    val canContinue = isUsable && passwordProblem == null
    val submit = { if (canContinue && !isWorking) { focusManager.clearFocus(); viewModel.continueUseNostr() } }

    val scanner = rememberLauncherForActivityResult(ScanContract()) { result ->
        result.contents?.trim()?.let(viewModel::setUseNostrInput)
    }

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            "Who are you on Nostr?",
            color = PrimaryText,
            fontSize = 24.sp,
            fontWeight = FontWeight.SemiBold,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            "Paste your public key or name@domain to read. Add your private key to post too.",
            color = SecondaryText,
            fontSize = 15.sp,
            lineHeight = 21.sp,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(20.dp))

        OutlinedTextField(
            value = raw,
            onValueChange = viewModel::setUseNostrInput,
            placeholder = { Text("npub, name@domain, nsec or bunker://", fontFamily = FontFamily.Monospace, fontSize = 14.sp) },
            textStyle = androidx.compose.ui.text.TextStyle(fontFamily = FontFamily.Monospace, fontSize = 15.sp),
            singleLine = true,
            trailingIcon = {
                IconButton(onClick = {
                    scanner.launch(
                        ScanOptions().apply {
                            setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                            setPrompt("Scan your key or signer link")
                            setBeepEnabled(false)
                            setOrientationLocked(true)
                        },
                    )
                }) {
                    Icon(Icons.Default.QrCodeScanner, contentDescription = "Scan a QR code", tint = WizardAccent)
                }
            },
            // The keyboard covers Continue on a phone; its action does the same.
            keyboardOptions = KeyboardOptions(
                autoCorrectEnabled = false,
                keyboardType = KeyboardType.Ascii,
                imeAction = if (needsPassword) ImeAction.Next else ImeAction.Go,
            ),
            keyboardActions = KeyboardActions(onGo = { submit() }),
            colors = wizardTextFieldColors(),
            modifier = Modifier
                .fillMaxWidth()
                .semantics { contentDescription = "Your key or name" },
        )

        line?.let {
            Spacer(Modifier.height(16.dp))
            ModeCard(it)
        }

        if (needsPassword) {
            Spacer(Modifier.height(16.dp))
            OutlinedTextField(
                value = password,
                onValueChange = viewModel::setUseNostrPassword,
                label = {
                    Text(
                        if (kind is IdentityInput.EncryptedSecretKey) "Password for this key"
                        else "Choose a password to lock your key on this device",
                    )
                },
                singleLine = true,
                visualTransformation = if (showPassword) VisualTransformation.None else PasswordVisualTransformation(),
                trailingIcon = {
                    IconButton(onClick = { showPassword = !showPassword }) {
                        Icon(
                            if (showPassword) Icons.Default.VisibilityOff else Icons.Default.Visibility,
                            contentDescription = if (showPassword) "Hide password" else "Show password",
                            tint = WizardAccent,
                        )
                    }
                },
                isError = isNewPassword && password.isNotEmpty() && password.length < 8,
                supportingText = if (isNewPassword && password.isNotEmpty() && password.length < 8) {
                    { Text("Password must be at least 8 characters", color = ErrorRed) }
                } else null,
                keyboardOptions = KeyboardOptions(
                    keyboardType = KeyboardType.Password,
                    imeAction = if (isNewPassword) ImeAction.Next else ImeAction.Go,
                ),
                keyboardActions = KeyboardActions(onGo = { submit() }),
                colors = wizardTextFieldColors(),
                modifier = Modifier.fillMaxWidth(),
            )
            // A new password for a pasted nsec: typed twice, as on New to
            // Nostr, because a typo here means the key can't be unlocked.
            if (isNewPassword) {
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(
                    value = confirm,
                    onValueChange = viewModel::setUseNostrConfirm,
                    label = { Text("Confirm password") },
                    singleLine = true,
                    visualTransformation = if (showPassword) VisualTransformation.None else PasswordVisualTransformation(),
                    isError = confirm.isNotEmpty() && confirm != password,
                    supportingText = if (confirm.isNotEmpty() && confirm != password) {
                        { Text("Passwords do not match", color = ErrorRed) }
                    } else null,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Go),
                    keyboardActions = KeyboardActions(onGo = { submit() }),
                    colors = wizardTextFieldColors(),
                    modifier = Modifier.fillMaxWidth(),
                )
                Spacer(Modifier.height(8.dp))
                Text(
                    "Nobody can reset this password for you, not even us. Write it down.",
                    color = SecondaryText,
                    fontSize = 12.sp,
                    lineHeight = 16.sp,
                )
            }
        }

        if (!kind.canPost) {
            Spacer(Modifier.height(16.dp))
            SignerSection(
                isAmberAvailable = isAmberAvailable,
                showingSigner = showingSigner,
                onShowSigner = { showingSigner = true },
                onAmber = viewModel::useAmberForUseNostr,
                pairing = {
                    NostrConnectPairing(
                        accent = WizardAccent,
                        onPaired = { request, signerPubkey -> viewModel.pairNostrConnect(request, signerPubkey) },
                    )
                },
            )
        }

        error?.let {
            Spacer(Modifier.height(12.dp))
            Text(it, color = ErrorRed, fontSize = 13.sp, textAlign = TextAlign.Center)
        }

        Spacer(Modifier.height(20.dp))
        WizardPrimaryButton(
            text = if (isWorking) "Checking…" else "Continue",
            enabled = canContinue,
            isLoading = isWorking,
            onClick = submit,
        )
        Spacer(Modifier.height(12.dp))
        Text(
            "Your private key stays on this device. It's never sent anywhere.",
            color = Muted,
            fontSize = 12.sp,
            textAlign = TextAlign.Center,
        )
    }
}

/** What the pasted thing means, in one line. Shape first, then the checksum,
 *  so a cut-off key says so before Continue. */
private fun modeLine(kind: IdentityInput, checksumOK: Boolean): ModeLine? {
    if ((kind is IdentityInput.PublicKey || kind is IdentityInput.SecretKey) && !checksumOK) {
        return ModeLine(
            ModeTone.ERROR, "That doesn't look complete",
            "Check that you copied the whole key. npub and nsec keys are 63 characters.",
        )
    }
    return when (kind) {
        IdentityInput.Empty -> null
        is IdentityInput.PublicKey -> ModeLine(
            ModeTone.READ, "Read-only",
            "You can see your feed, notes and follows. Add your private key later in Settings to post.",
        )
        is IdentityInput.Nip05 -> ModeLine(
            ModeTone.READ, "${kind.name} · read-only",
            "We'll look this up when you continue. Add your private key later in Settings to post.",
        )
        is IdentityInput.SecretKey -> ModeLine(
            ModeTone.POST, "You can post",
            "Post, reply, DM and zap. Your key is saved encrypted on this device.",
        )
        is IdentityInput.EncryptedSecretKey -> ModeLine(
            ModeTone.POST, "Encrypted key · you can post", "Enter the password you locked it with.",
        )
        is IdentityInput.RemoteSigner -> ModeLine(
            ModeTone.POST, "Signer link · you can post", "Continue connects to your signer app. It approves each post.",
        )
        IdentityInput.HexKey, IdentityInput.Unrecognised -> ModeLine(ModeTone.ERROR, "That doesn't look right", kind.hint.orEmpty())
    }
}

@Composable
private fun ModeCard(line: ModeLine) {
    val color = when (line.tone) {
        ModeTone.READ -> SecondaryText
        ModeTone.POST -> SuccessGreen
        ModeTone.ERROR -> ErrorRed
    }
    val icon = when (line.tone) {
        ModeTone.READ -> Icons.Default.Visibility
        ModeTone.POST -> Icons.Default.CheckCircle
        ModeTone.ERROR -> Icons.Default.ErrorOutline
    }
    Row(
        verticalAlignment = Alignment.Top,
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(WizardBgCard)
            .border(1.dp, color.copy(alpha = 0.5f), RoundedCornerShape(12.dp))
            .padding(12.dp)
            .semantics(mergeDescendants = true) {},
    ) {
        Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(10.dp))
        Column {
            Text(line.title, color = PrimaryText, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(3.dp))
            Text(line.detail, color = SecondaryText, fontSize = 13.sp, lineHeight = 18.sp)
        }
    }
}

/** "or", then the signer apps: Amber when it's installed (Android's usual
 *  signer), and a nostrconnect:// pairing for any other. */
@Composable
private fun SignerSection(
    isAmberAvailable: Boolean,
    showingSigner: Boolean,
    onShowSigner: () -> Unit,
    onAmber: () -> Unit,
    pairing: @Composable () -> Unit,
) {
    if (showingSigner) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            pairing()
            Spacer(Modifier.height(8.dp))
            Text("Or paste a bunker:// link from any signer app above.", color = Muted, fontSize = 12.sp)
        }
        return
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        HorizontalDivider(Modifier.weight(1f), color = WizardBorderSubtle)
        Text("or", color = Muted, fontSize = 12.sp, modifier = Modifier.padding(horizontal = 8.dp))
        HorizontalDivider(Modifier.weight(1f), color = WizardBorderSubtle)
    }
    Spacer(Modifier.height(12.dp))
    if (isAmberAvailable) {
        SignerButton("Use Amber", onAmber)
        Spacer(Modifier.height(8.dp))
    }
    SignerButton("Use a signer app", onShowSigner)
}

@Composable
private fun SignerButton(text: String, onClick: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(WizardBgElevated)
            .clickable(onClick = onClick),
    ) {
        Icon(Icons.Default.Key, contentDescription = null, tint = PrimaryText, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(8.dp))
        Text(text, color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
    }
}
