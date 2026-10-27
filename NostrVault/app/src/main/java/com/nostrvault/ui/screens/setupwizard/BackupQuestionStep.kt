package com.nostrvault.ui.screens

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.SuccessGreen
import com.nostrvault.ui.theme.TertiaryText

// ══════════════════════════════════════════════════════════════════
// Do you have a Vault backup?
// ══════════════════════════════════════════════════════════════════

/**
 * Asked of people who already use Nostr, after their key and before the
 * relay check (VaultBackupQuestion). Yes picks a backup file and restores
 * it; setup then finishes without a relay import. No carries on to the
 * relay check as before. Same as iOS `VaultBackupQuestionStep`.
 */
@Composable
internal fun BackupQuestionStep(viewModel: SetupWizardViewModel, onComplete: () -> Unit) {
    val state by viewModel.backupQuestion.collectAsState()
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri?.let { viewModel.restoreBackupFromQuestion(it) }
    }

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            "Do you have a Vault backup?",
            color = PrimaryText,
            fontSize = 24.sp,
            fontWeight = FontWeight.SemiBold,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            "A backup file from Nostr Vault brings your notes back at once, without downloading them from relays again.",
            color = SecondaryText,
            fontSize = 15.sp,
            lineHeight = 21.sp,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(24.dp))

        when (state) {
            VaultBackupQuestion.State.Restoring -> StatusCard {
                CircularProgressIndicator(color = WizardAccent, strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
                Text("Restoring your backup…", color = SecondaryText, fontSize = 15.sp)
            }
            VaultBackupQuestion.State.Restored -> {
                StatusCard(borderColor = SuccessGreen.copy(alpha = 0.5f)) {
                    Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = SuccessGreen)
                    Text("Backup restored", color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.Medium)
                }
                Spacer(Modifier.height(16.dp))
                WizardPrimaryButton(text = "Continue", onClick = { viewModel.finishAfterBackupRestore(onComplete) })
            }
            else -> {
                WizardPrimaryButton(
                    text = "Yes, restore my backup",
                    onClick = { picker.launch(arrayOf("application/zip", "application/x-zip-compressed")) },
                )
                Spacer(Modifier.height(12.dp))
                OutlinedButton(
                    onClick = viewModel::answerNoBackup,
                    shape = RoundedCornerShape(12.dp),
                    colors = ButtonDefaults.outlinedButtonColors(containerColor = WizardBgCard),
                    border = androidx.compose.foundation.BorderStroke(1.dp, WizardBorderSubtle),
                    modifier = Modifier.fillMaxWidth().height(52.dp),
                ) {
                    Text("No, import from my relays", color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                }
                Spacer(Modifier.height(12.dp))
                Text(
                    "Backups are the .zip files from Settings › Backup & Restore.",
                    color = TertiaryText,
                    fontSize = 12.sp,
                    textAlign = TextAlign.Center,
                )
            }
        }
    }

    (state as? VaultBackupQuestion.State.Failed)?.let { failed ->
        AlertDialog(
            onDismissRequest = viewModel::dismissBackupError,
            confirmButton = { TextButton(onClick = viewModel::dismissBackupError) { Text("OK") } },
            title = { Text("Could not restore the backup") },
            text = { Text(failed.message) },
        )
    }
}

@Composable
private fun StatusCard(
    borderColor: androidx.compose.ui.graphics.Color = WizardBorderSubtle,
    content: @Composable () -> Unit,
) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(WizardBgCard)
            .border(if (borderColor == WizardBorderSubtle) 1.dp else 2.dp, borderColor, RoundedCornerShape(12.dp))
            .padding(16.dp),
    ) { content() }
}
