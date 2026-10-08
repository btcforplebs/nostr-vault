package com.nostrvault.ui.screens

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Block
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.SwapHoriz
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import androidx.activity.compose.rememberLauncherForActivityResult
import com.nostrvault.setup.IdentityInput
import com.nostrvault.setup.ImportTourStage
import com.nostrvault.setup.RelayCheck
import com.nostrvault.tutorials.TutorialContent
import com.nostrvault.ui.components.NostrConnectPairing
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.SuccessGreen
import java.text.NumberFormat
import kotlin.math.cos
import kotlin.math.sin

// The "I already use Nostr" path: one key field, a relay check, then the
// import tour. Same as iOS UseNostrSteps.swift (design: Tory's mockup,
// ~/.buzz/OUTBOX/i-use-nostr-mockup.html).

private val Muted = SecondaryText.copy(alpha = 0.6f)

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
    val canContinue = isUsable && (!needsPassword || password.isNotEmpty())
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
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Go),
                keyboardActions = KeyboardActions(onGo = { submit() }),
                colors = wizardTextFieldColors(),
                modifier = Modifier.fillMaxWidth(),
            )
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

// ══════════════════════════════════════════════════════════════════
// Relay check
// ══════════════════════════════════════════════════════════════════

/**
 * Between Your key and the import tour: checks which relays answer and have
 * this person's notes, so the import can't hang on a dead one. "Start
 * import" saves the picks to `importSeedRelays`, which is what the import reads.
 */
@Composable
internal fun RelayCheckStep(viewModel: SetupWizardViewModel) {
    val rows by viewModel.relayRows.collectAsState()
    val isChecking by viewModel.isCheckingRelays.collectAsState()
    val error by viewModel.error.collectAsState()
    var editing by rememberSaveable { mutableStateOf(false) }
    var newRelay by rememberSaveable { mutableStateOf("") }
    val onCount = rows.count { it.isOn }

    LaunchedEffect(Unit) { viewModel.startRelayCheck() }

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            if (isChecking) "Checking your relays" else "Ready to import",
            color = PrimaryText,
            fontSize = 24.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            if (isChecking) "Looking for your notes. This takes a few seconds." else RelayCheck.summary(rows),
            color = SecondaryText,
            fontSize = 15.sp,
            lineHeight = 21.sp,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(16.dp))

        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .background(WizardBgCard)
                .border(1.dp, WizardBorderSubtle, RoundedCornerShape(12.dp)),
        ) {
            rows.forEachIndexed { i, row ->
                RelayCheckRow(row, editing, onToggle = { viewModel.setRelayRowOn(row.url, it) })
                if (i < rows.lastIndex) HorizontalDivider(color = WizardBorderSubtle)
            }
        }

        if (editing) {
            Spacer(Modifier.height(12.dp))
            val add = { if (viewModel.addRelayCheckRow(newRelay)) newRelay = "" }
            OutlinedTextField(
                value = newRelay,
                onValueChange = { newRelay = it },
                placeholder = { Text("Add a relay, e.g. relay.example.com") },
                singleLine = true,
                trailingIcon = {
                    TextButton(onClick = add, enabled = RelayCheck.normalize(newRelay) != null) {
                        Text("Add", color = WizardAccent, fontWeight = FontWeight.SemiBold)
                    }
                },
                keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = KeyboardType.Uri, imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { add() }),
                colors = wizardTextFieldColors(),
                modifier = Modifier.fillMaxWidth(),
            )
        }

        if (!isChecking && onCount == 0) {
            TextButton(onClick = { viewModel.startRelayCheck(force = true) }, modifier = Modifier.heightIn(min = 48.dp)) {
                Text("Check again", color = WizardAccent, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
            }
        }
        error?.let {
            Spacer(Modifier.height(8.dp))
            Text(it, color = ErrorRed, fontSize = 13.sp, textAlign = TextAlign.Center)
        }

        Spacer(Modifier.height(20.dp))
        WizardPrimaryButton(
            text = "Start import",
            enabled = !isChecking && onCount > 0,
            onClick = viewModel::startImportFromRelayCheck,
        )
        TextButton(
            onClick = { editing = !editing },
            enabled = !isChecking,
            modifier = Modifier.heightIn(min = 48.dp),
        ) {
            Text(if (editing) "Done" else "Change import relays", color = WizardAccent, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

@Composable
private fun RelayCheckRow(row: RelayCheck.Row, editing: Boolean, onToggle: (Boolean) -> Unit) {
    val dot = when (row.result) {
        RelayCheck.Result.Checking -> Muted
        is RelayCheck.Result.Ready -> SuccessGreen
        is RelayCheck.Result.Slow -> WizardAccent
        else -> ErrorRed
    }
    val name = row.url.removePrefix("wss://")
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 14.dp, vertical = 10.dp)
            .then(
                if (editing) Modifier
                else Modifier.semantics(mergeDescendants = true) {},
            ),
    ) {
        Box(Modifier.size(8.dp).clip(CircleShape).background(dot))
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    name,
                    color = PrimaryText,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                if (row.isYours) {
                    Spacer(Modifier.width(6.dp))
                    Text(
                        "yours",
                        color = WizardAccent,
                        fontSize = 10.sp,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier
                            .clip(RoundedCornerShape(6.dp))
                            .background(WizardAccent.copy(alpha = 0.15f))
                            .padding(horizontal = 6.dp, vertical = 2.dp),
                    )
                }
            }
            Spacer(Modifier.height(2.dp))
            Text(row.result.label, color = SecondaryText, fontSize = 12.sp)
        }
        if (editing) {
            Switch(
                checked = row.isOn,
                onCheckedChange = onToggle,
                enabled = row.result.canImport,
                colors = SwitchDefaults.colors(checkedTrackColor = WizardAccent),
                modifier = Modifier.semantics { contentDescription = "Import from $name" },
            )
        }
    }
}

// ══════════════════════════════════════════════════════════════════
// Import tour
// ══════════════════════════════════════════════════════════════════

/** The small orange label over each lesson (mockup). */
private val TourKickers = listOf("WHY IMPORT", "HOW IT WORKS", "RELAYS", "OPTIONAL", "FEEDS")

/**
 * The import starts as soon as this shows. Over it, the import tour's lesson
 * cards at the reader's own pace, then a Ready card with real counts. Import
 * done first: "Jump in" shows under any card. Cards done first: the app can
 * open with the import still running (it lives in RelayImportService, not here).
 */
@Composable
internal fun ImportTourStep(viewModel: SetupWizardViewModel, onComplete: () -> Unit) {
    val isImporting by viewModel.tourIsImporting.collectAsState()
    val completed by viewModel.tourImportCompleted.collectAsState()
    val progress by viewModel.tourImportProgress.collectAsState()
    val status by viewModel.tourImportStatus.collectAsState()
    val counts by viewModel.tourCounts.collectAsState()
    val setupMode = viewModel.setupModeNow()
    val lessons = TutorialContent.importTour
    val lastIndex = lessons.size // the Ready card
    var index by rememberSaveable { mutableIntStateOf(0) }
    val done = completed && !isImporting
    // It ran and stopped without finishing: let them in anyway.
    val failed by viewModel.tourImportFailed.collectAsState()
    val stage = if (failed) ImportTourStage("The import stopped", 1) else ImportTourStage.from(status, done)
    // Kept running or not, the import carries on in RelayImportService.
    val enter = { viewModel.enterFromImportTour(sawEveryCard = index >= lastIndex, onComplete = onComplete) }

    LaunchedEffect(Unit) { viewModel.startImportTour() }
    LaunchedEffect(done) { if (done) viewModel.loadTourCounts() }

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text("Bringing your notes home", color = PrimaryText, fontSize = 24.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(16.dp))

        // Progress
        Column(
            Modifier
                .fillMaxWidth()
                .clearAndSetSemantics {
                    contentDescription = "Import"
                    stateDescription = stage.text
                },
        ) {
            Row(Modifier.fillMaxWidth()) {
                Text(
                    stage.text,
                    color = when {
                        done -> SuccessGreen
                        failed -> ErrorRed
                        else -> SecondaryText
                    },
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Medium,
                    modifier = Modifier.weight(1f),
                )
                Text("${stage.step} of ${ImportTourStage.STEP_COUNT}", color = Muted, fontSize = 12.sp)
            }
            Spacer(Modifier.height(6.dp))
            LinearProgressIndicator(
                progress = { if (done) 1f else progress.coerceAtLeast(0.02f) },
                color = if (done) SuccessGreen else WizardAccent,
                trackColor = WizardBgElevated,
                modifier = Modifier.fillMaxWidth(),
            )
        }
        Spacer(Modifier.height(16.dp))

        // Card
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 260.dp)
                .clip(RoundedCornerShape(16.dp))
                .background(WizardBgCard)
                .border(1.dp, WizardBorderSubtle, RoundedCornerShape(16.dp))
                .padding(18.dp),
        ) {
            if (index < lastIndex) {
                val lesson = lessons[index]
                Kicker(TourKickers[index])
                Spacer(Modifier.height(12.dp))
                Text(lesson.title, color = PrimaryText, fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(12.dp))
                Text(lesson.body, color = SecondaryText, fontSize = 15.sp, lineHeight = 21.sp)
                Spacer(Modifier.height(16.dp))
                ImportTourArt(index, Modifier.fillMaxWidth())
            } else {
                Kicker("READY")
                Spacer(Modifier.height(12.dp))
                ReadyCard(done, failed, counts, isReadOnly = setupMode == "browse", onKeepRunning = enter)
            }
            Spacer(Modifier.height(12.dp))
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                TextButton(
                    onClick = { index -= 1 },
                    enabled = index > 0,
                    modifier = Modifier.heightIn(min = 48.dp),
                ) {
                    Text("Back", color = if (index > 0) SecondaryText else Color.Transparent)
                }
                Spacer(Modifier.weight(1f))
                Pips(count = lastIndex + 1, index = index)
                Spacer(Modifier.weight(1f))
                if (index < lastIndex) {
                    TourButton("Next", enabled = true) { index += 1 }
                } else {
                    TourButton("Enter", enabled = done || failed, onClick = enter)
                }
            }
        }

        if (done && index < lastIndex) {
            Spacer(Modifier.height(16.dp))
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(SuccessGreen.copy(alpha = 0.12f))
                    .padding(12.dp),
            ) {
                Icon(Icons.Default.CheckCircle, contentDescription = null, tint = SuccessGreen, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text(
                    "Import done. Your notes are home.",
                    color = SuccessGreen,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Medium,
                    modifier = Modifier.weight(1f),
                )
                TourButton("Jump in", enabled = true, onClick = enter)
            }
        }
    }
}

@Composable
private fun Kicker(text: String) {
    Text(text, color = WizardAccent, fontSize = 11.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.sp)
}

@Composable
private fun TourButton(text: String, enabled: Boolean, onClick: () -> Unit) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .heightIn(min = 48.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(WizardGradient, alpha = if (enabled) 1f else 0.4f)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 18.dp),
    ) {
        Text(text, color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun Pips(count: Int, index: Int) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier.clearAndSetSemantics { contentDescription = "Card ${index + 1} of $count" },
    ) {
        repeat(count) { i ->
            Box(Modifier.size(6.dp).clip(CircleShape).background(if (i == index) WizardAccent else WizardBorderSubtle))
        }
    }
}

@Composable
private fun ReadyCard(
    done: Boolean,
    failed: Boolean,
    counts: Triple<Int, Int, Int>?,
    isReadOnly: Boolean,
    onKeepRunning: () -> Unit,
) {
    Text(
        when {
            done -> "Your notes are home"
            failed -> "The import stopped"
            else -> "Almost there"
        },
        color = PrimaryText,
        fontSize = 20.sp,
        fontWeight = FontWeight.SemiBold,
    )
    Spacer(Modifier.height(12.dp))
    if (failed) {
        Text(
            "Some of your notes may not be here yet. You can import again any time from Settings → Import.",
            color = SecondaryText,
            fontSize = 15.sp,
            lineHeight = 21.sp,
        )
    } else if (done) {
        Text("Everything we found is saved on this device.", color = SecondaryText, fontSize = 15.sp)
        counts?.let { (notes, likes, all) ->
            Spacer(Modifier.height(12.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                CountTile(notes, "notes", Modifier.weight(1f))
                CountTile(likes, "likes", Modifier.weight(1f))
                CountTile(all, "in all", Modifier.weight(1f))
            }
        }
        if (isReadOnly) {
            Spacer(Modifier.height(12.dp))
            Text("Read-only for now. Add your private key in Settings to post.", color = SecondaryText, fontSize = 13.sp)
        }
    } else {
        Text(
            "Still importing. That's normal for a long history, so you can wait here or keep it running in the background.",
            color = SecondaryText,
            fontSize = 15.sp,
            lineHeight = 21.sp,
        )
        TextButton(onClick = onKeepRunning, modifier = Modifier.heightIn(min = 48.dp)) {
            Text("Keep it running in the background", color = WizardAccent, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

@Composable
private fun CountTile(value: Int, label: String, modifier: Modifier) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = modifier
            .clip(RoundedCornerShape(10.dp))
            .background(WizardBgElevated)
            .padding(vertical = 10.dp)
            .semantics(mergeDescendants = true) {},
    ) {
        Text(NumberFormat.getIntegerInstance().format(value), color = PrimaryText, fontSize = 18.sp, fontWeight = FontWeight.Bold)
        Text(label, color = Muted, fontSize = 12.sp)
    }
}

// ══════════════════════════════════════════════════════════════════
// Lesson pictures
// ══════════════════════════════════════════════════════════════════

/** The small diagram under each lesson (the mockup's pictures, drawn with
 *  Material icons). Decorative: the text says the same thing. */
@Composable
private fun ImportTourArt(lesson: Int, modifier: Modifier = Modifier) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .height(110.dp)
            .clearAndSetSemantics {},
    ) {
        when (lesson) {
            0 -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    ArtSymbol(Icons.Default.Storage, SecondaryText, 22.dp, "relay")
                    Box(contentAlignment = Alignment.Center) {
                        ArtSymbol(Icons.Default.Storage, Muted, 22.dp, "deleted", Muted)
                        Icon(Icons.Default.Close, null, tint = ErrorRed, modifier = Modifier.size(16.dp).offset(y = (-7).dp))
                    }
                }
                Icon(Icons.AutoMirrored.Filled.ArrowForward, null, tint = WizardAccent, modifier = Modifier.size(20.dp))
                ArtSymbol(Icons.Default.PhoneAndroid, WizardAccent, 44.dp, "your copy", PrimaryText)
            }
            1 -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                ArtSymbol(Icons.Default.Language, Muted, 22.dp, "network", Muted)
                Icon(Icons.Default.Block, null, tint = ErrorRed, modifier = Modifier.size(18.dp))
                ArtSymbol(Icons.Default.PhoneAndroid, WizardAccent, 44.dp, "your relay", PrimaryText)
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Icon(Icons.Default.ArrowUpward, null, tint = WizardAccent, modifier = Modifier.size(16.dp))
                    Icon(Icons.AutoMirrored.Filled.ArrowForward, null, tint = WizardAccent, modifier = Modifier.size(16.dp))
                    Icon(Icons.Default.ArrowDownward, null, tint = WizardAccent, modifier = Modifier.size(16.dp))
                }
            }
            2 -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                ArtSymbol(Icons.Default.PhoneAndroid, WizardAccent, 44.dp, "yours", PrimaryText)
                Icon(Icons.AutoMirrored.Filled.ArrowForward, null, tint = WizardAccent, modifier = Modifier.size(20.dp))
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    repeat(3) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.Storage, null, tint = SecondaryText, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(4.dp))
                            Text("public", color = SecondaryText, fontSize = 10.sp, fontWeight = FontWeight.Medium)
                        }
                    }
                }
            }
            3 -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                Icon(Icons.Default.PhoneAndroid, null, tint = SecondaryText, modifier = Modifier.size(34.dp))
                Icon(Icons.Default.SwapHoriz, null, tint = Muted, modifier = Modifier.size(16.dp))
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Icon(Icons.Default.Computer, null, tint = WizardAccent, modifier = Modifier.size(46.dp))
                    Text("relay.you.com", color = PrimaryText, fontSize = 10.sp, fontWeight = FontWeight.Medium)
                    Text("up 24/7", color = SecondaryText, fontSize = 10.sp, fontWeight = FontWeight.Medium)
                }
            }
            else -> WebOfTrustArt()
        }
    }
}

@Composable
private fun ArtSymbol(icon: ImageVector, tint: Color, size: Dp, caption: String, captionColor: Color = SecondaryText) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Icon(icon, null, tint = tint, modifier = Modifier.size(size))
        Text(caption, color = captionColor, fontSize = 10.sp, fontWeight = FontWeight.Medium)
    }
}

/** You, your follows, and the people they follow. */
@Composable
private fun WebOfTrustArt() {
    val spokes = 6
    Box(Modifier.size(width = 120.dp, height = 100.dp)) {
        Canvas(Modifier.matchParentSize()) {
            val center = Offset(size.width / 2, size.height / 2)
            for (k in 0 until spokes) {
                val angle = k * Math.PI / 3
                val end = Offset(
                    center.x + (44.dp.toPx() * cos(angle)).toFloat(),
                    center.y + (38.dp.toPx() * sin(angle)).toFloat(),
                )
                drawLine(WizardAccent.copy(alpha = 0.5f), center, end, strokeWidth = 1.dp.toPx())
            }
        }
        for (k in 0 until spokes) {
            val angle = k * Math.PI / 3
            Icon(
                Icons.Default.AccountCircle, null, tint = SecondaryText,
                modifier = Modifier
                    .align(Alignment.Center)
                    .offset(x = (44 * cos(angle)).dp, y = (38 * sin(angle)).dp)
                    .size(20.dp),
            )
        }
        Icon(Icons.Default.AccountCircle, null, tint = WizardAccent, modifier = Modifier.align(Alignment.Center).size(30.dp))
    }
}
