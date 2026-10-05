package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenConfig
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.StateFlow
import javax.inject.Inject

/** Trust list refresh options: stored value -> label, worded as iOS. */
private val WOT_REFRESH_OPTIONS = listOf(
    "1h" to "Every hour", "12h" to "Every 12 hours", "24h" to "Every day", "168h" to "Every week",
)

@HiltViewModel
class RelayAccessSettingsViewModel @Inject constructor(
    private val configStore: ConfigStore,
) : ViewModel() {
    val config: StateFlow<HavenConfig> = configStore.config
    /** True while a saved change is restarting the relay onto it. */
    val isRestartingRelay: StateFlow<Boolean> = configStore.relayApplier.isRestarting

    fun setWotDepth(v: Int) = configStore.update { it.copy(chatRelayWotDepth = v.coerceIn(1, 5)) }
    fun setWotMinFollowers(v: Int) = configStore.update { it.copy(chatRelayMinFollowers = v.coerceIn(0, 100)) }
    fun setWotRefresh(v: String) = configStore.update { it.copy(wotRefreshInterval = v) }
    fun setMaxEvents(v: Int) = configStore.update { it.copy(outboxMaxEventsPerMinute = v.coerceIn(10, 1000)) }
    fun setMaxConnections(v: Int) = configStore.update { it.copy(outboxMaxConnectionsPerMinute = v.coerceIn(1, 100)) }
}

/**
 * Who may write to your relay's inbox and chat, and how fast (iOS
 * `RelayAccessSettingsView`). These used to be split between "Performance &
 * Limits" and "Global Web of Trust" in Advanced, although both answer the
 * same question.
 */
@Composable
fun RelayAccessSettingsScreen(
    onBack: () -> Unit,
    viewModel: RelayAccessSettingsViewModel = hiltViewModel(),
) {
    val config by viewModel.config.collectAsState()
    val isRestartingRelay by viewModel.isRestartingRelay.collectAsState()

    SettingsPage(title = "Who Can Reach You", onBack = onBack) {
        SettingsSectionLabel("Web of Trust")
        SettingsStepperRow("Follow Distance", config.chatRelayWotDepth, 1..5, help = SettingsHelp.RELAY_WOT_DEPTH, onChange = viewModel::setWotDepth)
        SettingsStepperRow("Minimum Followers", config.chatRelayMinFollowers, 0..100, help = SettingsHelp.RELAY_MIN_FOLLOWERS, onChange = viewModel::setWotMinFollowers)
        SettingsPickerRow(
            label = "Refresh Trust List",
            options = WOT_REFRESH_OPTIONS,
            selected = config.wotRefreshInterval,
            help = SettingsHelp.RELAY_WOT_REFRESH,
            onSelect = viewModel::setWotRefresh,
        )

        Spacer(Modifier.height(20.dp))

        SettingsSectionLabel("Rate Limits")
        SettingsStepperRow(
            label = "Events",
            value = config.outboxMaxEventsPerMinute,
            range = 10..1000,
            step = 10,
            valueText = "${config.outboxMaxEventsPerMinute} / min",
            help = SettingsHelp.RELAY_RATE_LIMITS,
            onChange = viewModel::setMaxEvents,
        )
        SettingsStepperRow(
            label = "Connections",
            value = config.outboxMaxConnectionsPerMinute,
            range = 1..100,
            valueText = "${config.outboxMaxConnectionsPerMinute} / min",
            onChange = viewModel::setMaxConnections,
        )
        // Both sections feed the relay's launch environment (RelayConfiguration).
        SettingsCaption("Changes on this page restart the relay automatically.")
        if (isRestartingRelay) SettingsCaption("Restarting relay…")
    }
}
