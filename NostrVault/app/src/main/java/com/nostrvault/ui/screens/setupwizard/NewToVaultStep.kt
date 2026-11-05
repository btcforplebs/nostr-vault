package com.nostrvault.ui.screens

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.TertiaryText

// ══════════════════════════════════════════════════════════════════
// New to Nostr Vault?
// ══════════════════════════════════════════════════════════════════

/**
 * Setup's second question, after the key on "I already use Nostr". Yes brings
 * the notes from relays (the relay check, then the import tour). No copies
 * from the other vault: its two scans take this step's place until they
 * link, fail or are cancelled. A backup zip is restored from Settings ›
 * Backup & Restore, not here (PLANS/NV_FIRST_RUN_ENTRY_PLAN_2026_11_05.md).
 */
@Composable
internal fun NewToVaultStep(
    viewModel: SetupWizardViewModel,
    onComplete: () -> Unit,
    otherVault: OtherDeviceViewModel = hiltViewModel(),
) {
    val copying by otherVault.ui.collectAsState()
    // FellBack draws nothing of its own: the flow only moves setup on to the relays.
    if (copying != OtherDeviceViewModel.Ui.Ask) {
        OtherDeviceFlow(viewModel, onComplete, otherVault)
        if (copying != OtherDeviceViewModel.Ui.FellBack) return
    }

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            NewToVault.TITLE,
            color = PrimaryText,
            fontSize = 24.sp,
            fontWeight = FontWeight.SemiBold,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            NewToVault.BODY,
            color = SecondaryText,
            fontSize = 15.sp,
            lineHeight = 21.sp,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(24.dp))
        WizardPrimaryButton(text = NewToVault.YES, onClick = viewModel::bringNotesFromRelays)
        Spacer(Modifier.height(12.dp))
        OutlinedButton(
            onClick = otherVault::yes,
            shape = RoundedCornerShape(12.dp),
            colors = ButtonDefaults.outlinedButtonColors(containerColor = WizardBgCard),
            border = BorderStroke(1.dp, WizardBorderSubtle),
            modifier = Modifier.fillMaxWidth().height(52.dp).testTag("setup.copyOtherVault"),
        ) {
            Text(NewToVault.NO, color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        }
        Spacer(Modifier.height(6.dp))
        Text(
            BringItOver.COPY_DETAIL,
            color = TertiaryText,
            fontSize = 12.sp,
            lineHeight = 16.sp,
            textAlign = TextAlign.Center,
        )
    }
}

/** The second question's words. Plain: no mesh, backup or relay-app words. */
object NewToVault {
    const val TITLE = "New to Nostr Vault?"
    const val BODY = "If this is your first Nostr Vault, we'll bring your notes from your relays. Already have it on another phone or computer? Copy from that one."
    const val YES = "Yes, bring my notes from relays"
    const val NO = "No, copy from my other vault"
}
