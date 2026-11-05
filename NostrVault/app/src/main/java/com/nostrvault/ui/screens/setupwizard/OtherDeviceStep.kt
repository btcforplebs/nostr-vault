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
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
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
 * "Already using Nostr Vault on another device?" (§5a), after the key and Who told you, before the backup question.
 * No goes on exactly as before. Yes links this phone to the other device with two scans; anything that doesn't link
 * carries on to the relays with one plain line. No mesh, address or role words here. Twin of iOS `BringItOverStep`.
 */
@Composable
internal fun OtherDeviceStep(
    wizard: SetupWizardViewModel,
    onComplete: () -> Unit,
    viewModel: OtherDeviceViewModel = hiltViewModel(),
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
    // Didn't link: today's relay setup, as if No had been tapped.
    LaunchedEffect(ui) { if (ui == OtherDeviceViewModel.Ui.FellBack) wizard.skipOtherDevice() }

    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        when (val s = ui) {
            OtherDeviceViewModel.Ui.Ask, OtherDeviceViewModel.Ui.FellBack -> {
                Title(BringItOver.QUESTION)
                Spacer(Modifier.height(12.dp))
                Choice(BringItOver.YES, BringItOver.YES_DETAIL, viewModel::yes, Modifier.testTag("setup.otherDevice.yes"))
                Choice(BringItOver.NO, BringItOver.NO_DETAIL, wizard::skipOtherDevice, Modifier.testTag("setup.otherDevice.no"))
            }
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
                WizardSecondaryButton(text = BringItOver.NO, onClick = viewModel::giveUp)
            }
            is OtherDeviceViewModel.Ui.Confirm -> {
                Title("Link this device?")
                Body(s.text)
                Small(s.shortAddress)
                Spacer(Modifier.height(8.dp))
                WizardPrimaryButton(text = "Link", onClick = viewModel::confirm)
                WizardSecondaryButton(text = BringItOver.NO, onClick = viewModel::giveUp)
            }
            is OtherDeviceViewModel.Ui.ShowMyCode -> {
                Title(BringItOver.showCodeTitle(s.name))
                Body(BringItOver.showCodeBody(s.name))
                Qr(s.uri)
                Waiting("Waiting for ${s.name}…")
                WizardSecondaryButton(text = BringItOver.NO, onClick = viewModel::giveUp)
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
                    WizardPrimaryButton(text = "Continue", onClick = wizard::skipOtherDevice)
                }
            }
        }
    }
}

/** No, or anything that didn't link: on to the backup question and the relays. */
internal fun SetupWizardViewModel.skipOtherDevice() {
    if (_step.value == WizardStep.OTHER_DEVICE) _step.value = stepAfter(WizardStep.OTHER_DEVICE)
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

/** One of the two answers: a big button with a line under it. */
@Composable
private fun Choice(title: String, detail: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = modifier.fillMaxWidth()) {
        WizardOptionCard(title = title, subtitle = detail, selected = false, onClick = onClick, modifier = Modifier.fillMaxWidth())
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
