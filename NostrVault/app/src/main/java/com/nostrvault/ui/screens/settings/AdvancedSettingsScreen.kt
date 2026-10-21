package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
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
import com.nostrvault.service.MediaCacheService
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import com.nostrvault.ui.screens.dashboard.formatSize
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import javax.inject.Inject

@HiltViewModel
class AdvancedSettingsViewModel @Inject constructor(
    private val configStore: ConfigStore,
    private val mediaCacheService: MediaCacheService,
    private val notificationManager: com.nostrvault.ui.notification.NotificationManager,
) : ViewModel() {
    private val _cacheBytes = MutableStateFlow<Long?>(null)
    /** Size of the media cache, null until measured (iOS cacheBytes). */
    val cacheBytes: StateFlow<Long?> = _cacheBytes.asStateFlow()

    fun measureCache() {
        viewModelScope.launch {
            _cacheBytes.value = withContext(Dispatchers.IO) { mediaCacheService.cacheSizeBytes() }
        }
    }

    val config: StateFlow<HavenConfig> = configStore.config
    /** True while a saved change is restarting the relay onto it. */
    val isRestartingRelay: StateFlow<Boolean> = configStore.relayApplier.isRestarting

    fun setMaxEvents(v: Int) = save { it.copy(outboxMaxEventsPerMinute = v.coerceIn(10, 1000)) }
    fun setMaxConnections(v: Int) = save { it.copy(outboxMaxConnectionsPerMinute = v.coerceIn(1, 100)) }
    fun setAutoplay(v: Boolean) = save { it.copy(autoplayVideos = v) }
    fun setDisableMediaCache(v: Boolean) = save { it.copy(disableMediaCache = v) }
    fun setPrefetch(v: Boolean) = save { it.copy(prefetchAvatars = v) }
    fun setCacheTTL(v: Int) = save { it.copy(cacheTTLDays = v) }
    fun setWotDepth(v: Int) = save { it.copy(chatRelayWotDepth = v.coerceIn(1, 5)) }
    fun setWotMinFollowers(v: Int) = save { it.copy(chatRelayMinFollowers = v.coerceIn(0, 100)) }
    fun setWotRefresh(v: String) = save { it.copy(wotRefreshInterval = v) }
    fun setAutoStartRelay(v: Boolean) = save { it.copy(autoStartRelay = v) }
    fun setUseLocalBlossomCache(v: Boolean) = save { it.copy(useLocalBlossomCache = v) }

    fun clearMediaCache() {
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { mediaCacheService.clearCache() }
            val freed = formatSize(result.bytesFreed)
            if (result.filesFailed == 0) {
                notificationManager.showToast("Cleared $freed of temporary copies")
            } else {
                notificationManager.showError(
                    "Cleared $freed, but ${result.filesFailed} files could not be removed",
                    style = com.nostrvault.ui.notification.ErrorStyle.WARNING,
                )
            }
            measureCache()
        }
    }

    companion object {
        /** The confirm text, with the size when it is known (iOS clearMessage). */
        fun clearMessage(bytes: Long?): String {
            val size = bytes?.let { formatSize(it) + " of " } ?: ""
            return "Removes ${size}temporary copies of images and videos. They download again when you view them. Your vault and your Blossom servers are not touched."
        }
    }

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

    private fun save(transform: (HavenConfig) -> HavenConfig) = configStore.update(transform)
}

/**
 * Database & Reset: the relay's storage engine, the external-relay switch and
 * Factory Reset (iOS AdvancedSettingsView). Media settings live in Media &
 * Cache and the inbox gates in Who Can Reach You, as on iPhone.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AdvancedSettingsScreen(
    onBack: () -> Unit,
    viewModel: AdvancedSettingsViewModel = hiltViewModel(),
) {
    val config by viewModel.config.collectAsState()
    val context = LocalContext.current
    var showResetDialog by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Database & Reset") },
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
            SectionLabel("Database")
            ReadOnlyRow("Engine", if (config.dbEngine == "lmdb") "LMDB" else "BadgerDB", SettingsHelp.ADV_DATABASE)

            Spacer(Modifier.height(20.dp))

            // Android only: another app's relay instead of the built-in one.
            SectionLabel("External Relay", SettingsHelp.RELAY_EXTERNAL)
            ExternalRelaySection(config) { enabled, relayURL, blossomURL ->
                RelayForegroundService.stop(context)
                viewModel.applyExternalRelay(enabled, relayURL, blossomURL) { relaunchApp(context) }
            }

            Spacer(Modifier.height(28.dp))

            SectionLabel("Danger Zone", SettingsHelp.ADV_FACTORY_RESET)
            Button(
                onClick = { showResetDialog = true },
                colors = ButtonDefaults.buttonColors(containerColor = ErrorRed),
                modifier = Modifier.fillMaxWidth(),
            ) { Text("Factory Reset") }

            Spacer(Modifier.height(32.dp))
        }
    }

    if (showResetDialog) {
        // iOS AdvancedSettingsView's alert; Android restarts into setup
        // rather than quitting.
        AlertDialog(
            onDismissRequest = { showResetDialog = false },
            title = { Text("Are you sure?") },
            text = { Text(FACTORY_RESET_MESSAGE) },
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

internal const val FACTORY_RESET_MESSAGE =
    "This action cannot be undone. All your relay data will be lost and the app will restart."

/** Relaunch the app from its launcher entry point in a fresh process. */
private fun relaunchApp(context: android.content.Context) {
    val intent = context.packageManager
        .getLaunchIntentForPackage(context.packageName)
        ?.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK or
            android.content.Intent.FLAG_ACTIVITY_CLEAR_TASK)
    context.startActivity(intent)
    Runtime.getRuntime().exit(0)
}
