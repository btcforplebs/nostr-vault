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
// Step: Your keys (New to Nostr path)
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

    // Only seen if making the key failed when Create an account was picked.
    // The "Welcome to Nostr" cards that used to come first were dropped
    // (setup screens r3, Logen 2026-11-22, same as iOS #2410).
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        error?.let { errorText ->
            Text(errorText, color = Color(0xFFEF4444), fontSize = 13.sp)
            Spacer(Modifier.height(8.dp))
        }

        WizardPrimaryButton(
            text = "Make My Key",
            enabled = !isLoading,
            isLoading = isLoading,
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
    // The nsec is shown in full: keep it out of screenshots and Recents.
    com.nostrvault.ui.components.SecureWindowEffect()
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
