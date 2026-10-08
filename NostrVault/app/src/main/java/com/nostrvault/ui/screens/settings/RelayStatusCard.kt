package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenConfig
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.relay.RelayForegroundService.RelayStatus
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject

@HiltViewModel
class RelayStatusCardViewModel @Inject constructor(configStore: ConfigStore) : ViewModel() {
    val config = configStore.config
}

/** The card's status word, as on iOS RelayStatusCard. */
enum class RelayCardStatus(val label: String) {
    RUNNING("Running"), STARTING("Starting…"), STOPPED("Stopped"), EXTERNAL("External");

    companion object {
        /** An external relay is another app's: its health isn't this app's to report. */
        fun of(status: RelayStatus, external: Boolean): RelayCardStatus = when {
            external -> EXTERNAL
            status == RelayStatus.RUNNING -> RUNNING
            status == RelayStatus.BOOTING || status == RelayStatus.IMPORTING -> STARTING
            else -> STOPPED
        }

        /** Where the relay answers: the external relay's URL, or the loopback address this app talks to. */
        fun address(config: HavenConfig): String =
            if (config.useExternalRelay) config.nostrURL.orEmpty() else "ws://127.0.0.1:${config.relayPort}"
    }
}

/**
 * Top of Settings: whether the relay on this phone is running and where it
 * answers, with Start Relay when it's stopped. iOS: RelayStatusCard in
 * SettingsView.swift.
 */
@Composable
fun RelayStatusCard(viewModel: RelayStatusCardViewModel = hiltViewModel()) {
    val context = LocalContext.current
    val config by viewModel.config.collectAsState()
    val relayStatus by RelayForegroundService.relayStatus.collectAsState()
    val status = RelayCardStatus.of(relayStatus, config.useExternalRelay)
    val color = when (status) {
        RelayCardStatus.RUNNING -> SuccessGreen
        RelayCardStatus.STARTING -> ZapOrange
        RelayCardStatus.STOPPED -> ErrorRed
        RelayCardStatus.EXTERNAL -> SecondaryText
    }
    val primary = LocalNostrVaultColors.current.primary

    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(CardBackground)
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Box(
                Modifier.size(44.dp).clip(RoundedCornerShape(10.dp)).background(primary.copy(alpha = 0.18f)),
                contentAlignment = Alignment.Center,
            ) { Icon(NostrVaultIcons.Relay, contentDescription = null, tint = primary, modifier = Modifier.size(22.dp)) }
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(SettingsHelp.RELAY_STATUS.title, color = PrimaryText, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                    InfoButton(SettingsHelp.RELAY_STATUS)
                }
                SelectionContainer {
                    Text(
                        RelayCardStatus.address(config),
                        color = SecondaryText, fontSize = 12.sp, fontFamily = FontFamily.Monospace,
                        maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                modifier = Modifier.clearAndSetSemantics { contentDescription = "Relay ${status.label}" },
            ) {
                Box(Modifier.size(8.dp).clip(CircleShape).background(color))
                Text(status.label, color = color, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
            }
        }
        if (status == RelayCardStatus.STOPPED) {
            Row(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(10.dp))
                    .background(SuccessGreen.copy(alpha = 0.18f))
                    .clickable(role = Role.Button) { RelayForegroundService.start(context) }
                    .heightIn(min = 44.dp)
                    .padding(vertical = 10.dp),
                horizontalArrangement = Arrangement.Center,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(NostrVaultIcons.PlayArrow, contentDescription = null, tint = SuccessGreen, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(6.dp))
                Text("Start Relay", color = SuccessGreen, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
            }
        }
    }
}
