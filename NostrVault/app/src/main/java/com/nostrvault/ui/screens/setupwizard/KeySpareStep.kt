package com.nostrvault.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.*

// ══════════════════════════════════════════════════════════════════
// Step: Back up your key (New to Nostr path)
// ══════════════════════════════════════════════════════════════════

/**
 * The second key step (setup screens r3, Way 1b), "Back up your key" (Logen
 * 2026-11-22: the step is a backup, not a spare). The key with lines down to
 * the two ways to back it up: written on paper or copied. No print option
 * anywhere: the key is shown here (masked until Show) to write down, next to
 * a visible Copy my key button. Next waits for "I backed up my key", which
 * only the user ticks: a copy clears from the clipboard after a minute, so it
 * never counts as a backup on its own. No Save to Passwords.
 */
@Composable
internal fun KeySpareStep(viewModel: SetupWizardViewModel) {
    val nsec = viewModel.generatedNsec.collectAsState().value
    var shown by remember { mutableStateOf(false) }
    var copied by remember { mutableStateOf(false) }
    var savedKey by remember { mutableStateOf(false) }
    if (nsec == null) {
        // Back past the key step and a new way in dropped the key: nothing to keep.
        Text("Go back to your key first.", color = SecondaryText, fontSize = 15.sp)
        return
    }
    // The nsec can be shown here: keep it out of screenshots and Recents.
    com.nostrvault.ui.components.SecureWindowEffect()

    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
        Spacer(Modifier.height(8.dp))
        KeyStepsStrip(KeyStepPart.BACKUP)
        Spacer(Modifier.height(22.dp))
        Text("Back up your key", color = PrimaryText, fontSize = 28.sp, fontWeight = FontWeight.Bold, modifier = Modifier.semantics { heading() })
        Spacer(Modifier.height(22.dp))
        BackupPicture()
        Spacer(Modifier.height(18.dp))
        SecretKeyCard(nsec, shown) { shown = !shown }
        Spacer(Modifier.height(12.dp))
        KeyCopyButton(nsec) { copied = it }
        Spacer(Modifier.height(14.dp))
        Text(
            "Write your key down on paper and keep it somewhere safe. If you lose this phone, your backup is the only way back in.",
            color = SecondaryText, fontSize = 15.sp, lineHeight = 21.sp, textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(10.dp))
        Text(
            if (copied) "Copied. Paste it somewhere safe within a minute; then the clipboard clears."
            else "Don't save it to Photos, Files or Google Drive.",
            color = WizardTextMuted, fontSize = 13.sp, lineHeight = 18.sp, textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(12.dp))
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .heightIn(min = 48.dp)
                .toggleable(value = savedKey, role = Role.Checkbox, onValueChange = { savedKey = it }),
        ) {
            Checkbox(
                checked = savedKey,
                onCheckedChange = null,
                colors = CheckboxDefaults.colors(checkedColor = WizardAccent, uncheckedColor = SecondaryText),
            )
            Spacer(Modifier.width(10.dp))
            Text("I backed up my key", color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.Medium)
        }
        Spacer(Modifier.height(20.dp))
        WizardPrimaryButton(text = "Next", enabled = savedKey, onClick = viewModel::advanceFromKeySpare)
        Spacer(Modifier.height(8.dp))
    }
}

/** The secret key, masked until Show, to write down. */
@Composable
private fun SecretKeyCard(nsec: String, shown: Boolean, onToggle: () -> Unit) {
    WizardCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Default.Key, contentDescription = null, tint = WizardAccent, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
            Text("Secret key", color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            TextButton(onClick = onToggle, modifier = Modifier.heightIn(min = 44.dp)) {
                Text(if (shown) "Hide" else "Show", color = WizardAccent, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
            }
        }
        Spacer(Modifier.height(6.dp))
        Text(
            text = if (shown) nsec else "\u2022".repeat(24),
            color = if (shown) WizardAccent else WizardTextMuted,
            fontSize = 13.sp,
            fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(8.dp))
                .background(WizardBgElevated)
                .border(1.dp, WizardBorderSubtle, RoundedCornerShape(8.dp))
                .padding(10.dp)
                .clearAndSetSemantics { contentDescription = if (shown) "Secret key shown" else "Secret key hidden" },
        )
    }
}

/** The key, wired down to the two ways to back it up: on paper and a copy. */
@Composable
private fun BackupPicture() {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier.clearAndSetSemantics { contentDescription = "Your key, backed up on paper or as a copy" },
    ) {
        Icon(Icons.Default.Key, contentDescription = null, tint = WizardAccent, modifier = Modifier.size(48.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(140.dp), modifier = Modifier.height(30.dp)) {
            Wire(done = false)
            Wire(done = false)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            BackupTile(Icons.Default.Edit, "On paper", done = false)
            BackupTile(Icons.Default.ContentCopy, "Copy", done = false)
        }
    }
}

@Composable
private fun Wire(done: Boolean) {
    val color = if (done) SuccessGreen else WizardBorderActive
    androidx.compose.foundation.Canvas(Modifier.width(2.dp).fillMaxHeight()) {
        drawLine(
            color = color,
            start = androidx.compose.ui.geometry.Offset(size.width / 2, 0f),
            end = androidx.compose.ui.geometry.Offset(size.width / 2, size.height),
            strokeWidth = size.width,
            pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 4.dp.toPx())),
        )
    }
}

@Composable
private fun BackupTile(icon: ImageVector, label: String, done: Boolean) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
        modifier = Modifier
            .size(width = 128.dp, height = 92.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(WizardBgCard)
            .border(if (done) 2.dp else 1.dp, if (done) SuccessGreen.copy(alpha = 0.6f) else WizardBorderSubtle, RoundedCornerShape(16.dp)),
    ) {
        Icon(if (done) Icons.Default.CheckCircle else icon, contentDescription = null, tint = if (done) SuccessGreen else WizardAccent, modifier = Modifier.size(26.dp))
        Spacer(Modifier.height(8.dp))
        Text(label, color = PrimaryText, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
    }
}
