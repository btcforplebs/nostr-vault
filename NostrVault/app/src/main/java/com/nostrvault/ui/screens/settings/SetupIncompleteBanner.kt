package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.relay.HavenConfig
import com.nostrvault.ui.navigation.Screen
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.TertiaryText
import com.nostrvault.ui.theme.WarningYellow
import com.nostrvault.ui.theme.WizardOrange

/** What sits above the groups at the top of Settings. */
internal enum class SettingsTopItem {
    /** Setup was never finished: the banner that opens the wizard. */
    SETUP_INCOMPLETE,
    /** Whether the relay on this phone is running (RelayStatusCard). */
    RELAY_STATUS,
}

/**
 * The top of Settings for [config]: the "Setup Incomplete" banner first while
 * setup isn't finished, then the relay card. iOS SettingsView puts the same
 * banner above RelayStatusCard while `!config.hasCompletedSetup`.
 */
internal fun settingsTopItems(config: HavenConfig): List<SettingsTopItem> = buildList {
    if (!config.hasCompletedSetup) add(SettingsTopItem.SETUP_INCOMPLETE)
    add(SettingsTopItem.RELAY_STATUS)
}

/** Where the banner goes: the setup wizard, which finishes setup and starts the relay. */
internal val SETUP_INCOMPLETE_DESTINATION: Screen = Screen.SetupWizard

/**
 * Whether a finished wizard goes back to where it was opened from: only to
 * Settings, which opened it from the banner. On first run the wizard is the
 * start of the app (nothing, or only the graph, behind it) and goes to the Feed.
 */
internal fun setupWizardReturnsToSettings(previousRoute: String?): Boolean = previousRoute == Screen.Settings.route

/**
 * "Setup Incomplete" at the top of Settings. Tapping it opens the setup
 * wizard. Twin of the banner in iOS SettingsView.iOSBody.
 */
@Composable
internal fun SetupIncompleteBanner(onClick: () -> Unit) {
    val shape = RoundedCornerShape(12.dp)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .fillMaxWidth()
            .clip(shape)
            .background(WizardOrange.copy(alpha = 0.15f))
            .border(BorderStroke(1.dp, WizardOrange.copy(alpha = 0.3f)), shape)
            .clickable(role = Role.Button, onClickLabel = "Complete setup", onClick = onClick)
            .padding(16.dp),
    ) {
        Icon(NostrVaultIcons.Alert, contentDescription = null, tint = WarningYellow, modifier = Modifier.size(26.dp))
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text("Setup Incomplete", color = PrimaryText, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            Text("Tap to complete setup and start your relay.", color = SecondaryText, fontSize = 13.sp)
        }
        Icon(NostrVaultIcons.Navigate, contentDescription = null, tint = TertiaryText, modifier = Modifier.size(16.dp))
    }
}
