package com.nostrvault.ui.screens

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.relay.HavenBridge
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.theme.*

/**
 * "Who told you about Nostr Vault?": scan their QR code or paste their npub
 * or link, follow them, then follow some of the people they follow. Skippable
 * at every point. On "Create an account" and "I already use Nostr" (with a key).
 */
@Composable
internal fun ReferrerStep(
    viewModel: SetupWizardViewModel,
    step: ReferrerStepViewModel = hiltViewModel(),
) {
    val phase by step.phase.collectAsState()
    val ownHex = remember { viewModel.ownerHexNow() }
    val next = { viewModel.advanceFromReferrer() }

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            "Who told you about Nostr Vault?",
            color = PrimaryText,
            fontSize = 24.sp,
            fontWeight = FontWeight.SemiBold,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            when (phase) {
                ReferrerStepViewModel.Phase.ENTER -> "Scan their QR code or paste their link or npub. You'll follow them, and can follow people they follow."
                ReferrerStepViewModel.Phase.FOUND -> "Follow them to see what they post."
                ReferrerStepViewModel.Phase.SUGGEST -> "Some of the people they follow. Untick anyone you don't want."
            },
            color = SecondaryText,
            fontSize = 15.sp,
            lineHeight = 21.sp,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(20.dp))
        when (phase) {
            ReferrerStepViewModel.Phase.ENTER -> EnterReferrer(step, ownHex, onSkip = { step.skip(); next() })
            ReferrerStepViewModel.Phase.FOUND -> FoundReferrer(step, onSkip = { step.skip(); next() })
            ReferrerStepViewModel.Phase.SUGGEST -> SuggestFollows(
                step,
                onFollow = { step.finish(); next() },
                onNotNow = { step.finishReferrerOnly(); next() },
            )
        }
    }
}

@Composable
private fun EnterReferrer(step: ReferrerStepViewModel, ownHex: String?, onSkip: () -> Unit) {
    val input by step.input.collectAsState()
    val error by step.error.collectAsState()
    val focus = LocalFocusManager.current
    val find = { focus.clearFocus(); step.find(ownHex) }
    val scanner = rememberLauncherForActivityResult(ScanContract()) { result ->
        result.contents?.trim()?.let { step.setInput(it); step.find(ownHex) }
    }
    OutlinedTextField(
        value = input,
        onValueChange = step::setInput,
        placeholder = { Text("nostrvault.app/p/… or npub", fontFamily = FontFamily.Monospace, fontSize = 14.sp) },
        textStyle = androidx.compose.ui.text.TextStyle(fontFamily = FontFamily.Monospace, fontSize = 15.sp),
        singleLine = true,
        trailingIcon = {
            IconButton(onClick = {
                scanner.launch(ScanOptions().apply {
                    setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                    setPrompt("Scan their Share profile code")
                    setBeepEnabled(false)
                    setOrientationLocked(true)
                })
            }) { Icon(Icons.Default.QrCodeScanner, contentDescription = "Scan a QR code", tint = WizardAccent) }
        },
        keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = KeyboardType.Uri, imeAction = ImeAction.Go),
        keyboardActions = KeyboardActions(onGo = { find() }),
        isError = error != null,
        colors = wizardTextFieldColors(),
        modifier = Modifier.fillMaxWidth().semantics { contentDescription = "Their link or npub" },
    )
    error?.let {
        Spacer(Modifier.height(8.dp))
        Text(it, color = ErrorRed, fontSize = 13.sp, textAlign = TextAlign.Center)
    }
    Spacer(Modifier.height(24.dp))
    WizardPrimaryButton(text = "Find them", enabled = input.isNotBlank(), onClick = find)
    Spacer(Modifier.height(4.dp))
    WizardSecondaryButton(text = "Skip", onClick = onSkip)
}

@Composable
private fun FoundReferrer(step: ReferrerStepViewModel, onSkip: () -> Unit) {
    val pk = step.referrer.collectAsState().value ?: return
    val profiles by step.profiles.collectAsState()
    val profile = profiles[pk]
    WizardCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            AvatarImage(url = profile?.pictureURL, pubkey = pk, size = 56.dp, displayName = profile?.bestName)
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(nameOf(pk, profile), color = PrimaryText, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(
                    profile?.nip05?.takeIf { it.isNotBlank() } ?: shortNpub(pk),
                    color = SecondaryText, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
            }
        }
        profile?.about?.takeIf { it.isNotBlank() }?.let {
            Spacer(Modifier.height(12.dp))
            Text(it, color = SecondaryText, fontSize = 13.sp, lineHeight = 18.sp, maxLines = 3, overflow = TextOverflow.Ellipsis)
        }
    }
    Spacer(Modifier.height(24.dp))
    WizardPrimaryButton(text = "Follow ${nameOf(pk, profile)}", onClick = step::followReferrer)
    Spacer(Modifier.height(4.dp))
    WizardSecondaryButton(text = "Not them? Change", onClick = step::change)
    WizardSecondaryButton(text = "Skip", onClick = onSkip)
}

@Composable
private fun SuggestFollows(step: ReferrerStepViewModel, onFollow: () -> Unit, onNotNow: () -> Unit) {
    val suggestions by step.suggestions.collectAsState()
    val ticked by step.ticked.collectAsState()
    val profiles by step.profiles.collectAsState()
    val list = suggestions
    when {
        list == null -> Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = 24.dp)) {
            CircularProgressIndicator(color = WizardAccent, strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(10.dp))
            Text("Finding who they follow…", color = SecondaryText, fontSize = 14.sp)
        }
        list.isEmpty() -> Text(
            "Their follow list didn't load, so there's no one to suggest. You'll still follow them.",
            color = SecondaryText, fontSize = 14.sp, textAlign = TextAlign.Center,
            modifier = Modifier.padding(vertical = 16.dp),
        )
        else -> WizardCard {
            list.forEach { pk ->
                val profile = profiles[pk]
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth().clickable { step.toggle(pk) }.padding(vertical = 6.dp),
                ) {
                    AvatarImage(url = profile?.pictureURL, pubkey = pk, size = 36.dp, displayName = profile?.bestName)
                    Spacer(Modifier.width(12.dp))
                    Text(nameOf(pk, profile), color = PrimaryText, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                    Checkbox(
                        checked = pk in ticked,
                        onCheckedChange = { step.toggle(pk) },
                        colors = CheckboxDefaults.colors(checkedColor = WizardAccent),
                    )
                }
            }
        }
    }
    Spacer(Modifier.height(24.dp))
    val count = list.orEmpty().count { it in ticked }
    WizardPrimaryButton(
        text = if (count == 0) "Continue" else "Follow $count ${if (count == 1) "person" else "people"}",
        enabled = list != null,
        onClick = onFollow,
    )
    Spacer(Modifier.height(4.dp))
    WizardSecondaryButton(text = "Not now", onClick = onNotNow)
}

private fun nameOf(pk: String, profile: FeedProfile?): String =
    profile?.bestName?.takeIf { !it.endsWith("...") } ?: shortNpub(pk)

private fun shortNpub(pk: String): String =
    HavenBridge.hexToNpub(pk)?.let { it.take(12) + "…" + it.takeLast(6) } ?: (pk.take(8) + "…")
