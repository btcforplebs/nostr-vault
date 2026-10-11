package com.nostrvault.ui.screens

import android.Manifest
import android.os.Build
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.*
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.launch

// ══════════════════════════════════════════════════════════════════
// Step 7b: Stay in the Loop (iOS PushNotificationStep)
// ══════════════════════════════════════════════════════════════════

@Composable
internal fun NotificationsStep(viewModel: SetupWizardViewModel) {
    var dms by rememberSaveable { mutableStateOf(true) }
    var zaps by rememberSaveable { mutableStateOf(true) }
    var mentions by rememberSaveable { mutableStateOf(true) }
    // Android 13+ asks for POST_NOTIFICATIONS here, instead of at launch.
    // Whatever the answer, setup moves on; Settings → Notifications can
    // change it later.
    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { viewModel.finishNotifications(enable = true, dms = dms, zaps = zaps, mentions = mentions) }

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(
            imageVector = NostrVaultIcons.Notifications,
            contentDescription = null,
            tint = WizardAccent,
            modifier = Modifier.size(56.dp),
        )
        Spacer(Modifier.height(20.dp))
        Text(
            text = "Stay in the Loop",
            color = PrimaryText,
            fontSize = 22.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = "Get notified about DMs, zaps, and mentions.",
            color = SecondaryText,
            fontSize = 14.sp,
            textAlign = TextAlign.Center,
        )

        Spacer(Modifier.height(20.dp))

        WizardCard {
            NotificationToggleRow(NostrVaultIcons.DMs, "Direct Messages", dms) { dms = it }
            HorizontalDivider(color = TertiaryText.copy(alpha = 0.2f))
            NotificationToggleRow(NostrVaultIcons.Zap, "Zaps", zaps) { zaps = it }
            HorizontalDivider(color = TertiaryText.copy(alpha = 0.2f))
            NotificationToggleRow(NostrVaultIcons.At, "Mentions", mentions) { mentions = it }
        }

        Spacer(Modifier.height(32.dp))

        WizardPrimaryButton(text = "Enable Notifications", onClick = {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                permissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
            } else {
                viewModel.finishNotifications(enable = true, dms = dms, zaps = zaps, mentions = mentions)
            }
        })
        Spacer(Modifier.height(8.dp))
        WizardSecondaryButton(text = "Not now", onClick = {
            viewModel.finishNotifications(enable = false, dms = dms, zaps = zaps, mentions = mentions)
        })
    }
}

@Composable
private fun NotificationToggleRow(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    checked: Boolean,
    onChange: (Boolean) -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .toggleable(value = checked, role = Role.Switch, onValueChange = onChange)
            .padding(vertical = 8.dp),
    ) {
        Icon(icon, contentDescription = null, tint = WizardAccent, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(12.dp))
        Text(label, color = PrimaryText, fontSize = 15.sp, modifier = Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = null)
    }
}
