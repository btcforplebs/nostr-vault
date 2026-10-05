package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenConfig
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import javax.inject.Inject

@HiltViewModel
class AdvancedSettingsViewModel @Inject constructor(
    private val configStore: ConfigStore,
) : ViewModel() {
    val config: StateFlow<HavenConfig> = configStore.config

    /**
     * Persists the external-relay choice to disk before [onDone] restarts the
     * app. The caller has asked the relay service to stop; exiting before its
     * onDestroy has closed the databases would leave them uncleanly shut.
     */
    fun applyExternalRelay(enabled: Boolean, relayURL: String, blossomURL: String, onDone: () -> Unit) {
        viewModelScope.launch {
            withTimeoutOrNull(8_000) {
                while (RelayForegroundService.serviceAlive) delay(100)
            }
            configStore.updateAsync {
                if (enabled) {
                    it.copy(useExternalRelay = true, externalRelayURL = relayURL, externalBlossomURL = blossomURL)
                } else {
                    it.copy(useExternalRelay = false)
                }
            }
            onDone()
        }
    }

    fun factoryReset(onDone: () -> Unit) {
        viewModelScope.launch {
            configStore.resetApp()
            onDone()
        }
    }
}

/**
 * "Database & Reset" (iOS `AdvancedSettingsView`). The media, trust and
 * rate-limit settings that used to share this screen now have their own
 * pages, as on iOS: Media & Cache and Who Can Reach You.
 */
@Composable
fun AdvancedSettingsScreen(
    onBack: () -> Unit,
    viewModel: AdvancedSettingsViewModel = hiltViewModel(),
) {
    val config by viewModel.config.collectAsState()
    val context = LocalContext.current
    var showResetDialog by remember { mutableStateOf(false) }

    SettingsPage(title = "Database & Reset", onBack = onBack) {
        SettingsSectionLabel("Database")
        SettingsReadOnlyRow(
            "Engine",
            if (config.dbEngine == "lmdb") "LMDB" else "BadgerDB",
            SettingsHelp.ADV_DATABASE,
        )

        Spacer(Modifier.height(28.dp))

        SettingsSectionLabel("Danger Zone")
        Button(
            onClick = { showResetDialog = true },
            colors = ButtonDefaults.buttonColors(containerColor = ErrorRed),
            modifier = Modifier.fillMaxWidth(),
        ) { Text("Factory Reset") }
        SettingsCaption("Deletes your configuration and returns the app to first-run setup.")
    }

    if (showResetDialog) {
        // iOS's title and structure; the message says what Android's reset
        // does (ConfigStore.resetApp deletes the config, then the app restarts).
        AlertDialog(
            onDismissRequest = { showResetDialog = false },
            title = { Text("Factory Reset?") },
            text = { Text("This action cannot be undone. Your settings will be deleted and the app will restart.") },
            confirmButton = {
                TextButton(onClick = {
                    showResetDialog = false
                    RelayForegroundService.stop(context)
                    viewModel.factoryReset { relaunchApp(context) }
                }) { Text("Reset Everything", color = ErrorRed) }
            },
            dismissButton = {
                TextButton(onClick = { showResetDialog = false }) { Text("Cancel") }
            },
        )
    }
}

/**
 * Android only: run against another app's relay instead of the built-in one.
 * Lives under Your Vault Relay, since it replaces that relay.
 */
@Composable
fun ExternalRelaySettingsScreen(
    onBack: () -> Unit,
    viewModel: AdvancedSettingsViewModel = hiltViewModel(),
) {
    val config by viewModel.config.collectAsState()
    val context = LocalContext.current

    SettingsPage(title = "External Relay", onBack = onBack) {
        ExternalRelaySection(config) { enabled, relayURL, blossomURL ->
            RelayForegroundService.stop(context)
            viewModel.applyExternalRelay(enabled, relayURL, blossomURL) { relaunchApp(context) }
        }
    }
}

/** Relaunch the app from its launcher entry point in a fresh process. */
private fun relaunchApp(context: android.content.Context) {
    val intent = context.packageManager
        .getLaunchIntentForPackage(context.packageName)
        ?.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK or
            android.content.Intent.FLAG_ACTIVITY_CLEAR_TASK)
    context.startActivity(intent)
    Runtime.getRuntime().exit(0)
}
