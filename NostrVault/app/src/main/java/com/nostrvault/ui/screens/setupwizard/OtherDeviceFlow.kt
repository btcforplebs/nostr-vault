package com.nostrvault.ui.screens

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import com.journeyapps.barcodescanner.BarcodeEncoder
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.SuccessGreen
import com.nostrvault.ui.theme.TertiaryText

/**
 * "Copy from my other vault", once picked as the No to "New to Nostr Vault?" (§5a): links this phone to the other device with two
 * scans. Anything that doesn't link carries on to the relays with one plain line; Cancel goes back to the question,
 * and "Lost your other device?" goes straight on to the relays. No mesh, address or role words here. Twin of iOS
 * `BringItOverFlow`.
 */
@Composable
internal fun OtherDeviceFlow(
    wizard: SetupWizardViewModel,
    onComplete: () -> Unit,
    viewModel: OtherDeviceViewModel,
) {
    val ui by viewModel.ui.collectAsState()
    val scanner = rememberLauncherForActivityResult(ScanContract()) { result -> viewModel.onScanned(result.contents) }
    val scan = {
        scanner.launch(
            ScanOptions().apply {
                setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                setPrompt("Scan the code on your other device")
                setBeepEnabled(false)
                setOrientationLocked(true)
            },
        )
    }
    LaunchedEffect(viewModel) { viewModel.openCamera.collect { scan() } }
    // Didn't link: today's relay import, as if "Yes, bring my notes from relays" had been tapped.
    // Copied: the normal relay import still runs next (#1720 twin), so the copy's "done" is cleared first.
    LaunchedEffect(ui) {
        if (ui == OtherDeviceViewModel.Ui.Copied) {
            wizard.relayImportService.dismissImportProgress()
            viewModel.reset()
            wizard.bringNotesFromRelays()
        }
        if (ui == OtherDeviceViewModel.Ui.FellBack) {
            viewModel.reset()
            wizard.bringNotesFromRelays()
        }
    }

    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        when (val s = ui) {
            // The question (NewToVaultStep) draws these; the flow has nothing of its own to show.
            OtherDeviceViewModel.Ui.Ask, OtherDeviceViewModel.Ui.FellBack -> Unit
            OtherDeviceViewModel.Ui.Starting -> {
                Title(BringItOver.SCAN_TITLE)
                CircularProgressIndicator(color = WizardAccent, strokeWidth = 2.dp, modifier = Modifier.size(24.dp))
            }
            is OtherDeviceViewModel.Ui.Scan -> {
                Title(BringItOver.SCAN_TITLE)
                Body(BringItOver.SCAN_BODY)
                s.note?.let { Note(it) }
                Spacer(Modifier.height(8.dp))
                WizardPrimaryButton(text = "Scan its code", onClick = scan)
                WizardSecondaryButton(text = BringItOver.CANCEL, onClick = viewModel::giveUp)
                LostDevice { viewModel.giveUp(); wizard.bringNotesFromRelays() }
            }
            is OtherDeviceViewModel.Ui.Confirm -> {
                Title("Link this device?")
                Body(s.text)
                Small(s.shortAddress)
                Spacer(Modifier.height(8.dp))
                WizardPrimaryButton(text = "Link", onClick = viewModel::confirm)
                WizardSecondaryButton(text = BringItOver.CANCEL, onClick = viewModel::giveUp)
                LostDevice { viewModel.giveUp(); wizard.bringNotesFromRelays() }
            }
            is OtherDeviceViewModel.Ui.ShowMyCode -> {
                Title(BringItOver.showCodeTitle(s.name))
                Body(BringItOver.showCodeBody(s.name))
                Qr(s.uri)
                Waiting("Waiting for ${s.name}…")
                WizardSecondaryButton(text = BringItOver.CANCEL, onClick = viewModel::giveUp)
                LostDevice { viewModel.giveUp(); wizard.bringNotesFromRelays() }
            }
            is OtherDeviceViewModel.Ui.CheckWords -> {
                Title("Do these words match?")
                Body("${s.name} shows four words. Link only if they are the same as these.")
                Text(s.words.joinToString("  "), color = PrimaryText, fontSize = 22.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
                Small(s.shortAddress)
                if (s.tapped) Waiting("Waiting for ${s.name}…")
                else {
                    WizardPrimaryButton(text = "They match", onClick = viewModel::wordsMatch)
                    WizardSecondaryButton(text = "They don't match", onClick = viewModel::giveUp)
                }
            }
            is OtherDeviceViewModel.Ui.Copying -> {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite }) {
                    Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = SuccessGreen)
                    Text(BringItOver.linkedLine(s.name), color = PrimaryText, fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
                }
                Waiting(BringItOver.copyingLine(s.name))
                if (s.status.isNotBlank()) Small(s.status)
                Body("Your notes from your relays come next.")
            }
            is OtherDeviceViewModel.Ui.AskAccounts -> CopyAccountsAskView(s.accounts, onAnswer = viewModel::answerAccounts)
            OtherDeviceViewModel.Ui.Copied -> Unit
        }
    }
}

/** The way out for someone whose other device is gone: the relay import instead (plan §1). */
@Composable
private fun LostDevice(onClick: () -> Unit) {
    TextButton(onClick = onClick, modifier = Modifier.fillMaxWidth().testTag("setup.lostOtherDevice")) {
        Text(BringItOver.LOST_DEVICE, color = WizardAccent, fontSize = 14.sp, textAlign = TextAlign.Center)
    }
}

@Composable
private fun Title(text: String) {
    Text(text, color = PrimaryText, fontSize = 24.sp, lineHeight = 30.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
}

@Composable
private fun Body(text: String) {
    Text(text, color = SecondaryText, fontSize = 15.sp, lineHeight = 21.sp, textAlign = TextAlign.Center)
}

@Composable
private fun Small(text: String) {
    Text(text, color = TertiaryText, fontSize = 12.sp, textAlign = TextAlign.Center)
}

@Composable
private fun Note(text: String) {
    Text(text, color = ErrorRed, fontSize = 14.sp, textAlign = TextAlign.Center,
        modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
}

@Composable
private fun Waiting(text: String) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        CircularProgressIndicator(color = WizardAccent, strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
        Text(text, color = SecondaryText, fontSize = 14.sp)
    }
}

/** This phone's code, black on white, ECC M (contract §1). */
@Composable
private fun Qr(uri: String) {
    val bitmap = remember(uri) {
        runCatching {
            BarcodeEncoder().encodeBitmap(uri, BarcodeFormat.QR_CODE, 720, 720, mapOf(EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M, EncodeHintType.MARGIN to 2))
        }.getOrNull()
    } ?: return
    Image(bitmap.asImageBitmap(), contentDescription = "This phone's code",
        modifier = Modifier.size(260.dp).background(Color.White, RoundedCornerShape(12.dp)).padding(10.dp))
}
