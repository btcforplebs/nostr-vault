package com.nostrvault.ui.screens.pairing

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.style.TextOverflow
import com.nostrvault.fips.DeviceRole
import com.nostrvault.ui.screens.settings.fipsmesh.icon
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import com.journeyapps.barcodescanner.BarcodeEncoder
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.SuccessGreen
import com.nostrvault.ui.theme.WindowBackground

/**
 * Add a device: the two-scan link (PLANS/NV_TWO_SCAN_PAIRING_PLAN.md). Opens on this phone's code; "Scan their code
 * instead" makes this phone the one that scans first. Each code shows as text with Copy, and Paste instead takes the
 * other device's code or a bare mesh address (a Linux box, the browser relay page) for the one-way add. Twin of iOS
 * `PairShowQRView` / `PairScanView` / `PairPasteField` / `PairByAddressView` / `PairLinkedView`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PairDeviceScreen(onBack: () -> Unit, viewModel: PairDeviceViewModel = hiltViewModel()) {
    val ui by viewModel.ui.collectAsState()
    val scanner = rememberLauncherForActivityResult(ScanContract()) { result -> viewModel.onScanned(result.contents) }
    val launchScan = { prompt: String ->
        scanner.launch(
            ScanOptions().apply {
                setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                setPrompt(prompt)
                setBeepEnabled(false)
                setOrientationLocked(true)
            },
        )
    }
    // A's camera opens on its own after a good hello; B's when it chooses to scan.
    LaunchedEffect(viewModel) {
        viewModel.openCamera.collect {
            launchScan("Scan the code on your other device")
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Add a device") },
                navigationIcon = { IconButton(onClick = onBack) { Icon(NostrVaultIcons.Back, contentDescription = "Back") } },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = WindowBackground, titleContentColor = PrimaryText, navigationIconContentColor = PrimaryText),
            )
        },
        containerColor = WindowBackground,
    ) { padding ->
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp),
            modifier = Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 12.dp),
        ) {
            when (val s = ui) {
                is PairDeviceViewModel.Ui.NoMesh -> {
                    Title("Turn on the mesh first")
                    Body("Your devices link over the mesh. Turning it on gives this phone its own address.")
                    s.error?.let { Note(it, ErrorRed) }
                    if (s.starting) CircularProgressIndicator(color = LocalNostrVaultColors.current.primary)
                    else Primary("Turn on the mesh", viewModel::turnOnMesh)
                }
                is PairDeviceViewModel.Ui.ShowCode -> {
                    Title("Scan this with your other device")
                    Body("Open Add a device on your other device and scan this code, or paste it there. This phone's camera opens by itself after that.")
                    QrCode(s.uri)
                    CodeText(s.uri)
                    Body("Works for ${s.secondsLeft / 60}:${(s.secondsLeft % 60).toString().padStart(2, '0')}", small = true)
                    s.note?.let { Note(it, ErrorRed) }
                    Secondary("Scan their code instead", viewModel::scanInstead)
                    PasteField(viewModel::pasted)
                }
                is PairDeviceViewModel.Ui.ScanTheirs -> {
                    Title("${s.name} scanned this phone")
                    Body("Scan its screen to finish.")
                    s.note?.let { Note(it, ErrorRed) }
                    Primary("Scan its screen") { launchScan("Scan the code on ${s.name}") }
                    PasteField(viewModel::pasted)
                }
                is PairDeviceViewModel.Ui.ScanFirst -> {
                    Title("Scan your other device")
                    Body("On your other device, open Add a device so it shows its code, then scan it here.")
                    s.note?.let { Note(it, ErrorRed) }
                    Primary("Scan its code") { launchScan("Scan the code on your other device") }
                    Secondary("Show this phone's code instead", viewModel::showCode)
                    PasteField(viewModel::pasted)
                }
                is PairDeviceViewModel.Ui.ConfirmRole -> {
                    Title("Add this device?")
                    Body(s.text)
                    Address(s.shortAddress)
                    Primary("Add it", viewModel::confirmRole)
                    Secondary("Cancel", onBack)
                }
                is PairDeviceViewModel.Ui.ShowMyCode -> {
                    Title("Now let ${s.name} scan this")
                    Body("Hold this phone up to ${s.name}'s camera, or paste this code there. It finishes by itself.")
                    QrCode(s.uri)
                    CodeText(s.uri)
                    Waiting("Waiting for ${s.name}…")
                }
                is PairDeviceViewModel.Ui.CheckWords -> {
                    Title("Do these words match?")
                    Body("${s.name} shows four words. Link only if they are the same as these.")
                    Text(
                        s.words.joinToString("  "),
                        color = PrimaryText, fontSize = 22.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center,
                        modifier = Modifier.testTag("pair.words"),
                    )
                    Address(s.shortAddress)
                    if (s.tapped) Waiting("Waiting for ${s.name}…")
                    else {
                        Primary("They match", viewModel::wordsMatch)
                        Secondary("They don't match", onBack)
                    }
                }
                is PairDeviceViewModel.Ui.SwitchAccount -> {
                    Title("Another account")
                    Body(s.text)
                    Primary("Switch") { viewModel.switchAccount(s.npub) }
                    Secondary("Cancel", onBack)
                }
                is PairDeviceViewModel.Ui.ByAddress -> ByAddressStep(s.npub, viewModel::addByAddress, onCancel = viewModel::showCode)
                is PairDeviceViewModel.Ui.Linked -> {
                    Text("Linked ✓ ${s.name}", color = SuccessGreen, fontSize = 22.sp, fontWeight = FontWeight.Bold,
                        modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
                    if (s.already) Body(com.nostrvault.fips.MeshPairing.ALREADY_LINKED_TEXT)
                    if (s.keepOpen) Body(com.nostrvault.fips.OtherVaultCopy.KEEP_OPEN_LINE)
                    if (s.copy.isNotEmpty()) Body(s.copy)
                    Body("It shows a green dot under Your devices once the two meet on the mesh.", small = true)
                    Primary("Done", onBack)
                }
                is PairDeviceViewModel.Ui.Stopped -> {
                    Note(s.text, ErrorRed)
                    Primary("Start again", viewModel::showCode)
                    Secondary("Close", onBack)
                }
            }
        }
    }
}

@Composable
private fun Title(text: String) {
    Text(text, color = PrimaryText, fontSize = 20.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center,
        modifier = Modifier.fillMaxWidth().semantics { heading() })
}

@Composable
private fun Body(text: String, small: Boolean = false) {
    Text(text, color = SecondaryText, fontSize = if (small) 13.sp else 15.sp, lineHeight = if (small) 18.sp else 21.sp,
        textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
}

@Composable
private fun Note(text: String, color: Color) {
    Text(text, color = color, fontSize = 14.sp, textAlign = TextAlign.Center,
        modifier = Modifier.fillMaxWidth().semantics { liveRegion = LiveRegionMode.Polite })
}

@Composable
private fun Address(shortAddress: String) {
    Text(shortAddress, color = SecondaryText, fontSize = 13.sp, fontFamily = FontFamily.Monospace)
}

@Composable
private fun Waiting(text: String) {
    Box(contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
            CircularProgressIndicator(color = LocalNostrVaultColors.current.primary, modifier = Modifier.size(24.dp), strokeWidth = 2.dp)
            Text(text, color = SecondaryText, fontSize = 14.sp)
        }
    }
}

@Composable
private fun Primary(text: String, onClick: () -> Unit) {
    Button(
        onClick = onClick,
        colors = ButtonDefaults.buttonColors(containerColor = LocalNostrVaultColors.current.primary),
        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
    ) { Text(text, fontWeight = FontWeight.SemiBold) }
}

@Composable
private fun Secondary(text: String, onClick: () -> Unit) {
    TextButton(onClick = onClick, modifier = Modifier.heightIn(min = 48.dp)) {
        Text(text, color = LocalNostrVaultColors.current.primary)
    }
}

/** The pairing code, black on white with a quiet zone, ECC M (contract §1: it must read from a phone screen). */
@Composable
private fun QrCode(uri: String) {
    val bitmap = remember(uri) {
        runCatching {
            BarcodeEncoder().encodeBitmap(uri, BarcodeFormat.QR_CODE, 720, 720, mapOf(EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M, EncodeHintType.MARGIN to 2))
        }.getOrNull()
    }
    if (bitmap == null) {
        Note(com.nostrvault.fips.MeshPairing.UNREADABLE, ErrorRed)
        return
    }
    Spacer(Modifier.height(4.dp))
    Image(
        bitmap.asImageBitmap(),
        contentDescription = "Pairing code",
        modifier = Modifier.size(260.dp).background(Color.White, RoundedCornerShape(12.dp)).padding(10.dp).testTag("pair.qr"),
    )
}

/** The code under the QR as text, with Copy, for pasting on the other device (iOS `PairCodeText`). */
@Composable
private fun CodeText(code: String) {
    val clipboard = LocalClipboardManager.current
    var copied by remember(code) { mutableStateOf(false) }
    Text(
        code, color = SecondaryText, fontSize = 11.sp, fontFamily = FontFamily.Monospace, lineHeight = 15.sp,
        textAlign = TextAlign.Center, maxLines = 3, overflow = TextOverflow.Ellipsis,
        modifier = Modifier.fillMaxWidth().testTag("pair.code"),
    )
    OutlinedButton(
        onClick = { clipboard.setText(AnnotatedString(code)); copied = true },
        modifier = Modifier.heightIn(min = 48.dp).testTag("pair.copy"),
    ) {
        Icon(if (copied) Icons.Filled.Check else NostrVaultIcons.Copy, contentDescription = null, tint = LocalNostrVaultColors.current.primary, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(6.dp))
        Text(if (copied) "Copied" else COPY_CODE, color = LocalNostrVaultColors.current.primary)
    }
}

internal const val COPY_CODE = "Copy code"
internal const val PASTE_INSTEAD = "Paste instead"

/**
 * "Paste instead", on the code and scan steps (iOS `PairPasteField`): the other device's code as text, or a plain
 * mesh address (npub1…) for a Linux box or the browser relay page. [onPaste] -> words to show, or null when taken.
 */
@Composable
private fun PasteField(onPaste: (String) -> String?) {
    val clipboard = LocalClipboardManager.current
    var text by rememberSaveable { mutableStateOf("") }
    var error by rememberSaveable { mutableStateOf<String?>(null) }
    Spacer(Modifier.height(4.dp))
    HorizontalDivider(color = SecondaryText.copy(alpha = 0.2f))
    Column(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
        Text(PASTE_INSTEAD, color = PrimaryText, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
            modifier = Modifier.semantics { heading() })
        OutlinedTextField(
            value = text, onValueChange = { text = it; error = null }, maxLines = 4,
            placeholder = { Text("The other device's code, or a mesh address", fontSize = 13.sp) },
            isError = error != null,
            textStyle = LocalTextStyle.current.copy(fontFamily = FontFamily.Monospace, fontSize = 13.sp),
            modifier = Modifier.fillMaxWidth().testTag("pair.paste"),
        )
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            OutlinedButton(
                onClick = { clipboard.getText()?.text?.let { text = it; error = null } },
                modifier = Modifier.heightIn(min = 48.dp),
            ) {
                Icon(Icons.Filled.ContentPaste, contentDescription = null, tint = LocalNostrVaultColors.current.primary, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(6.dp))
                Text("Paste", color = LocalNostrVaultColors.current.primary)
            }
            Spacer(Modifier.weight(1f))
            Button(
                onClick = { error = onPaste(text) },
                enabled = text.isNotBlank(),
                colors = ButtonDefaults.buttonColors(containerColor = LocalNostrVaultColors.current.primary),
                modifier = Modifier.heightIn(min = 48.dp).testTag("pair.paste.use"),
            ) { Text("Use", fontWeight = FontWeight.SemiBold) }
        }
        error?.let {
            Text(it, color = ErrorRed, fontSize = 13.sp, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
        }
        Text(
            "A Linux box or the browser relay page shows only its mesh address (npub1…). Paste that here to add it.",
            color = SecondaryText, fontSize = 13.sp, lineHeight = 18.sp,
        )
    }
}

/** The one-way add for a pasted mesh address: what it is and a name (iOS `PairByAddressView`). */
@Composable
private fun ByAddressStep(npub: String, onAdd: (String, String, DeviceRole) -> String?, onCancel: () -> Unit) {
    val colors = LocalNostrVaultColors.current
    var role by rememberSaveable(npub) { mutableStateOf(DeviceRole.HOME_VAULT) }
    var name by rememberSaveable(npub) { mutableStateOf("") }
    var error by rememberSaveable(npub) { mutableStateOf<String?>(null) }
    Title("Add this device?")
    Body("Add this device by its address. It's added on this side only.")
    Address(com.nostrvault.fips.MeshPairing.shortAddress(npub))
    Column(Modifier.fillMaxWidth()) {
        Text("This is", color = SecondaryText, fontSize = 13.sp, modifier = Modifier.padding(bottom = 4.dp).semantics { heading() })
        DeviceRole.entries.forEachIndexed { i, r ->
            if (i > 0) HorizontalDivider(color = SecondaryText.copy(alpha = 0.2f))
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)
                    .semantics { selected = r == role }
                    .clickable(role = Role.RadioButton) { role = r; error = null }
                    .padding(vertical = 10.dp),
            ) {
                Icon(r.icon, contentDescription = null, tint = colors.primary, modifier = Modifier.size(24.dp))
                Spacer(Modifier.width(12.dp))
                Text(r.label, color = PrimaryText, fontSize = 16.sp, modifier = Modifier.weight(1f))
                if (r == role) Icon(Icons.Filled.Check, contentDescription = "Selected", tint = colors.primary)
            }
        }
        Text(role.blurb, color = SecondaryText, fontSize = 13.sp, lineHeight = 18.sp, modifier = Modifier.padding(top = 6.dp))
        if (role == DeviceRole.HOME_VAULT) {
            Text(
                "To let others fetch your photos from it, add it on Media Servers: its mesh address is then public. It must let your account write to its relay. " +
                    "Direct-message attachments are never sent there.",
                color = SecondaryText, fontSize = 13.sp, lineHeight = 18.sp, modifier = Modifier.padding(top = 6.dp),
            )
        }
    }
    OutlinedTextField(value = name, onValueChange = { name = it }, singleLine = true, placeholder = { Text("Name (optional)") },
        modifier = Modifier.fillMaxWidth().testTag("pair.byAddress.name"))
    error?.let { Note(it, ErrorRed) }
    Primary("Add") { error = onAdd(npub, name, role) }
    Secondary("Cancel", onCancel)
}
