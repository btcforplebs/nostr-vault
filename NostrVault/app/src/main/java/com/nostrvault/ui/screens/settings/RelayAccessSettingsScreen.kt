package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.WindowBackground

/** Refresh Trust List options: stored value -> label (iOS RelayAccessSettingsView). */
internal val WOT_REFRESH_OPTIONS = listOf(
    "1h" to "Every hour", "12h" to "Every 12 hours", "24h" to "Every day", "168h" to "Every week",
)

/**
 * Who Can Reach You: who may write to your relay's inbox and chat, and how
 * fast (iOS RelayAccessSettingsView). These used to be split between
 * "Performance & Limits" and "Global Web of Trust" in Advanced, although both
 * answer the same question.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RelayAccessSettingsScreen(
    onBack: () -> Unit,
    viewModel: AdvancedSettingsViewModel = hiltViewModel(),
) {
    val config by viewModel.config.collectAsState()
    val isRestartingRelay by viewModel.isRestartingRelay.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Who Can Reach You") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(NostrVaultIcons.Back, contentDescription = "Back")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = WindowBackground,
                    titleContentColor = PrimaryText,
                    navigationIconContentColor = PrimaryText,
                ),
            )
        },
        containerColor = WindowBackground,
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
        ) {
            SectionLabel("Web of Trust")
            StepperRow("Follow Distance", config.chatRelayWotDepth, 1..5, 1, SettingsHelp.RELAY_WOT_DEPTH) {
                viewModel.setWotDepth(it)
            }
            StepperRow("Minimum Followers", config.chatRelayMinFollowers, 0..100, 1, SettingsHelp.RELAY_MIN_FOLLOWERS) {
                viewModel.setWotMinFollowers(it)
            }
            PickerRow("Refresh Trust List", WOT_REFRESH_OPTIONS, config.wotRefreshInterval, SettingsHelp.RELAY_WOT_REFRESH) {
                viewModel.setWotRefresh(it)
            }

            Spacer(Modifier.height(20.dp))

            SectionLabel("Rate Limits")
            StepperRow("Events", config.outboxMaxEventsPerMinute, 10..1000, 10, SettingsHelp.RELAY_RATE_LIMITS, unit = " / min") {
                viewModel.setMaxEvents(it)
            }
            StepperRow("Connections", config.outboxMaxConnectionsPerMinute, 1..100, 1, unit = " / min") {
                viewModel.setMaxConnections(it)
            }
            Caption("Changes restart the relay automatically.")
            if (isRestartingRelay) Caption("Restarting relay…")

            Spacer(Modifier.height(32.dp))
        }
    }
}
