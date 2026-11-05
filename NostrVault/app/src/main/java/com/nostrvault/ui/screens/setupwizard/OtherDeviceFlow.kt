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
import com.nostrvault.relay.HavenBridge
import com.nostrvault.tutorials.TutorialCenter
import com.nostrvault.tutorials.TutorialID
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.SuccessGreen
import com.nostrvault.ui.theme.TertiaryText

/**
 * "Copy from my other vault", once picked in the import choice (§5a): links this phone to the other device with two
 * scans. Anything that doesn't link carries on to the relays with one plain line; Cancel goes back to the choice. No
 * mesh, address or role words here. Twin of iOS `BringItOverFlow`.
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
    // Didn't link: today's relay import, as if "No, import from my relays" had been tapped.
    LaunchedEffect(ui) {
        if (ui == OtherDeviceViewModel.Ui.FellBack) {
            viewModel.reset()
            wizard.answerNoBackup()
        }
    }

    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        when (val s = ui) {
            // The import choice draws these; the flow has nothing of its own to show.
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
            }
            is OtherDeviceViewModel.Ui.Confirm -> {
                Title("Link this device?")
                Body(s.text)
                Small(s.shortAddress)
                Spacer(Modifier.height(8.dp))
                WizardPrimaryButton(text = "Link", onClick = viewModel::confirm)
                WizardSecondaryButton(text = BringItOver.CANCEL, onClick = viewModel::giveUp)
            }
            is OtherDeviceViewModel.Ui.ShowMyCode -> {
                Title(BringItOver.showCodeTitle(s.name))
                Body(BringItOver.showCodeBody(s.name))
                Qr(s.uri)
                Waiting("Waiting for ${s.name}…")
                WizardSecondaryButton(text = BringItOver.CANCEL, onClick = viewModel::giveUp)
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
            is OtherDeviceViewModel.Ui.Linked -> {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite }) {
                    Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = SuccessGreen)
                    Text(BringItOver.linkedLine(s.name), color = PrimaryText, fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
                }
                if (s.copies) {
                    Body("Your vault copies from ${s.name} once setup finishes. You can use the app while it does; Vault shows how far it got.")
                    WizardPrimaryButton(text = "Continue", onClick = {
                        viewModel.watchCopy()
                        wizard.finishAfterLink(onComplete)
                    })
                } else {
                    Body("Your notes come from your relays next.")
                    WizardPrimaryButton(text = "Continue", onClick = wizard::answerNoBackup)
                }
            }
        }
    }
}

/** Linked a Mac: setup is done; the relay copies from it once it starts, so the relay import and its tour don't run. */
internal fun SetupWizardViewModel.finishAfterLink(onComplete: () -> Unit) {
    val account = HavenBridge.decodeNpub(configStore.config.value.ownerNpub).orEmpty()
    TutorialCenter.skip(TutorialID.IMPORT_TOUR, account)
    completeSetup(onComplete)
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
