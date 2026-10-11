package com.nostrvault.ui.screens

import android.content.Context
import androidx.compose.animation.*
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.*

// ══════════════════════════════════════════════════════════════════
// Step: Nostr Intro (New to Nostr path)
// ══════════════════════════════════════════════════════════════════

@Composable
internal fun NostrIntroStep(viewModel: SetupWizardViewModel) {
    val generatedNsec by viewModel.generatedNsec.collectAsState()
    val generatedNpub by viewModel.generatedNpub.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val error by viewModel.error.collectAsState()

    // Read from the view model, so Back from the password page shows the
    // same key instead of offering to make a new one.
    val nsec = generatedNsec
    if (nsec != null) {
        NewKeysPage(npub = generatedNpub.orEmpty(), nsec = nsec, onContinue = viewModel::advanceFromNostrIntro)
        return
    }

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        // Card 1: What is Nostr
        WizardCard {
            Text(
                text = "Welcome to Nostr",
                color = PrimaryText,
                fontSize = 20.sp,
                fontWeight = FontWeight.SemiBold,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(12.dp))
            Text(
                text = "Nostr is an open social protocol. You own your identity " +
                    "through a cryptographic keypair -- no company controls your " +
                    "account. Your posts are broadcast to relays and can be read " +
                    "by anyone.",
                color = SecondaryText,
                fontSize = 15.sp,
                lineHeight = 22.sp,
                textAlign = TextAlign.Center,
            )
        }

        Spacer(Modifier.height(16.dp))

        // Card 2: Why Nostr Vault is unique
        WizardCard {
            Text(
                text = "Your Personal Archive",
                color = PrimaryText,
                fontSize = 20.sp,
                fontWeight = FontWeight.SemiBold,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(12.dp))
            Text(
                text = "Nostr Vault runs a HAVEN relay right on your device. " +
                    "Every note, message, and media file you interact with is " +
                    "archived locally. Your data stays with you -- not on " +
                    "someone else's server.",
                color = SecondaryText,
                fontSize = 15.sp,
                lineHeight = 22.sp,
                textAlign = TextAlign.Center,
            )
        }

        Spacer(Modifier.height(20.dp))

        error?.let { errorText ->
            Text(errorText, color = Color(0xFFEF4444), fontSize = 13.sp)
            Spacer(Modifier.height(8.dp))
        }

        WizardPrimaryButton(
            text = "Create My Account",
            enabled = !isLoading,
            onClick = viewModel::generateNewUserKeys,
        )
    }
}

/**
 * Both new keys explained, the nsec readable in full to write down, and
 * Continue held until "I saved my secret key" is ticked. Tapping a card
 * copies it. Same as iOS (#399).
 */
@Composable
private fun NewKeysPage(npub: String, nsec: String, onContinue: () -> Unit) {
    val context = LocalContext.current
    var savedKey by remember { mutableStateOf(false) }
    var copiedKey by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(copiedKey) {
        if (copiedKey != null) {
            kotlinx.coroutines.delay(1_500)
            copiedKey = null
        }
    }
    fun copy(value: String) {
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
        val clip = android.content.ClipData.newPlainText("Nostr key", value)
        // Keeps the nsec out of the clipboard preview (Android 13+).
        if (value == nsec) {
            clip.description.extras = android.os.PersistableBundle().apply {
                putBoolean("android.content.extra.IS_SENSITIVE", true)
            }
        }
        clipboard.setPrimaryClip(clip)
        copiedKey = value
    }

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text("Your Keys", color = PrimaryText, fontSize = 24.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(6.dp))
        Text(
            text = "Two keys replace a username and password.",
            color = SecondaryText,
            fontSize = 15.sp,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(14.dp))
        NewKeyCard(
            icon = Icons.Default.Person,
            title = "Public key",
            caption = "Your name on Nostr. Share it freely.",
            value = npub,
            isSecret = false,
            copied = copiedKey == npub,
            onCopy = { copy(npub) },
        )
        Spacer(Modifier.height(14.dp))
        NewKeyCard(
            icon = Icons.Default.Key,
            title = "Secret key",
            caption = "Your password to Nostr. Anyone who has it can post as you, so never share it.",
            value = nsec,
            isSecret = true,
            copied = copiedKey == nsec,
            onCopy = { copy(nsec) },
        )
        Spacer(Modifier.height(8.dp))
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 48.dp)
                .toggleable(value = savedKey, role = Role.Checkbox, onValueChange = { savedKey = it }),
        ) {
            Checkbox(
                checked = savedKey,
                onCheckedChange = null,
                colors = CheckboxDefaults.colors(checkedColor = WizardAccent, uncheckedColor = SecondaryText),
            )
            Spacer(Modifier.width(10.dp))
            Text("I saved my secret key", color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.Medium)
        }
        Spacer(Modifier.height(8.dp))
        WizardPrimaryButton(text = "Continue", enabled = savedKey, onClick = onContinue)
    }
}

@Composable
private fun NewKeyCard(
    icon: ImageVector,
    title: String,
    caption: String,
    value: String,
    isSecret: Boolean,
    copied: Boolean,
    onCopy: () -> Unit,
) {
    WizardCard(
        modifier = Modifier
            .clip(RoundedCornerShape(16.dp))
            .clickable(onClickLabel = "Copy $title", onClick = onCopy),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, contentDescription = null, tint = if (isSecret) WizardAccent else SecondaryText, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
            Text(title, color = PrimaryText, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            Text(
                text = if (copied) "Copied" else "Copy",
                color = if (copied) SuccessGreen else WizardAccent,
                fontSize = 13.sp,
                fontWeight = FontWeight.Medium,
            )
        }
        Spacer(Modifier.height(8.dp))
        Text(caption, color = SecondaryText, fontSize = 13.sp, lineHeight = 18.sp)
        Spacer(Modifier.height(8.dp))
        Text(
            text = value,
            color = if (isSecret) WizardAccent else SecondaryText,
            fontSize = 12.sp,
            fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
            // The npub only needs recognising; the nsec has to be readable in
            // full to write it down.
            maxLines = if (isSecret) Int.MAX_VALUE else 1,
            overflow = if (isSecret) TextOverflow.Clip else TextOverflow.Ellipsis,
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(8.dp))
                .background(WizardBgElevated)
                .border(1.dp, WizardBorderSubtle, RoundedCornerShape(8.dp))
                .padding(10.dp),
        )
        if (isSecret) {
            Spacer(Modifier.height(8.dp))
            Row(verticalAlignment = Alignment.Top) {
                Icon(Icons.Default.Shield, contentDescription = null, tint = PrimaryText.copy(alpha = 0.85f), modifier = Modifier.size(14.dp))
                Spacer(Modifier.width(6.dp))
                Text(
                    "Nobody can recover it for you, not even us.",
                    color = PrimaryText.copy(alpha = 0.85f),
                    fontSize = 12.sp,
                    lineHeight = 16.sp,
                )
            }
        }
    }
}
