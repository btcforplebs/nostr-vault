package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
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
import kotlinx.coroutines.launch
import javax.inject.Inject

/** Cache TTL options: value (days) -> label. 0 = Never. */
private val CACHE_TTL_OPTIONS = listOf(
    1 to "1 day", 3 to "3 days", 7 to "7 days", 14 to "14 days", 30 to "30 days", 0 to "Never",
)

/** WoT refresh options: stored value -> label. */
private val WOT_REFRESH_OPTIONS = listOf(
    "1h" to "1 Hour", "12h" to "12 Hours", "24h" to "24 Hours", "168h" to "7 Days",
)

@HiltViewModel
class AdvancedSettingsViewModel @Inject constructor(
    private val configStore: ConfigStore,
    private val mediaCacheService: MediaCacheService,
) : ViewModel() {
    val config: StateFlow<HavenConfig> = configStore.config

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

    fun clearMediaCache() = mediaCacheService.clearCache()

    fun factoryReset(onDone: () -> Unit) {
        viewModelScope.launch {
            configStore.resetApp()
            onDone()
        }
    }

    private fun save(transform: (HavenConfig) -> HavenConfig) = configStore.update(transform)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AdvancedSettingsScreen(
    onBack: () -> Unit,
    viewModel: AdvancedSettingsViewModel = hiltViewModel(),
) {
    val config by viewModel.config.collectAsState()
    val colors = LocalNostrVaultColors.current
    val context = LocalContext.current
    var showResetDialog by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Advanced") },
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
            // ── Performance & Limits ──────────────────────────────
            SectionLabel("Performance & Limits")
            StepperRow("Max Events / min", config.outboxMaxEventsPerMinute, 10..1000, 10) {
                viewModel.setMaxEvents(it)
            }
            StepperRow("Max Connections / min", config.outboxMaxConnectionsPerMinute, 1..100, 1) {
                viewModel.setMaxConnections(it)
            }
            Caption("Protects your relay from spam and abuse. Restart the relay to apply.")

            Spacer(Modifier.height(20.dp))

            // ── Database ──────────────────────────────────────────
            SectionLabel("Database")
            ReadOnlyRow("Engine", if (config.dbEngine == "lmdb") "LMDB" else "BadgerDB")

            Spacer(Modifier.height(20.dp))

            // ── Media ─────────────────────────────────────────────
            SectionLabel("Media")
            ToggleRow("Autoplay Videos", config.autoplayVideos, viewModel::setAutoplay)
            ToggleRow("Disable Media Cache", config.disableMediaCache, viewModel::setDisableMediaCache)
            ToggleRow("Prefetch Profile Pictures", config.prefetchAvatars, viewModel::setPrefetch)
            PickerRow("Cache TTL", CACHE_TTL_OPTIONS, config.cacheTTLDays) { viewModel.setCacheTTL(it) }
            TextButton(onClick = { viewModel.clearMediaCache() }) {
                Text("Clear Media Cache", color = ErrorRed)
            }

            Spacer(Modifier.height(20.dp))

            // ── Global Web of Trust ───────────────────────────────
            SectionLabel("Global Web of Trust")
            StepperRow("Depth", config.chatRelayWotDepth, 1..5, 1) { viewModel.setWotDepth(it) }
            StepperRow("Minimum Followers", config.chatRelayMinFollowers, 0..100, 1) {
                viewModel.setWotMinFollowers(it)
            }
            PickerRow("Refresh Interval", WOT_REFRESH_OPTIONS, config.wotRefreshInterval) {
                viewModel.setWotRefresh(it)
            }

            Spacer(Modifier.height(20.dp))

            // ── Diagnostics & Startup ─────────────────────────────
            SectionLabel("Diagnostics & Startup")
            ToggleRow("Auto-start Relay", config.autoStartRelay, viewModel::setAutoStartRelay)
            OutlinedButton(
                onClick = {
                    RelayForegroundService.stop(context)
                    RelayForegroundService.start(context)
                },
                modifier = Modifier.padding(top = 8.dp),
            ) { Text("Restart Relay") }

            Spacer(Modifier.height(28.dp))

            // ── Danger Zone ───────────────────────────────────────
            SectionLabel("Danger Zone")
            Button(
                onClick = { showResetDialog = true },
                colors = ButtonDefaults.buttonColors(containerColor = ErrorRed),
                modifier = Modifier.fillMaxWidth(),
            ) { Text("Factory Reset") }
            Caption("Deletes your configuration and returns the app to first-run setup.")

            Spacer(Modifier.height(32.dp))
        }
    }

    if (showResetDialog) {
        AlertDialog(
            onDismissRequest = { showResetDialog = false },
            title = { Text("Factory Reset?") },
            text = { Text("This deletes your configuration and cannot be undone.") },
            confirmButton = {
                TextButton(onClick = {
                    showResetDialog = false
                    RelayForegroundService.stop(context)
                    viewModel.factoryReset {
                        // Relaunch the app from its launcher entry point.
                        val intent = context.packageManager
                            .getLaunchIntentForPackage(context.packageName)
                            ?.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK or
                                android.content.Intent.FLAG_ACTIVITY_CLEAR_TASK)
                        context.startActivity(intent)
                        Runtime.getRuntime().exit(0)
                    }
                }) { Text("Reset Everything", color = ErrorRed) }
            },
            dismissButton = {
                TextButton(onClick = { showResetDialog = false }) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(
        text = text.uppercase(),
        color = SecondaryText,
        fontSize = 12.sp,
        fontWeight = FontWeight.SemiBold,
        letterSpacing = 1.sp,
        modifier = Modifier.padding(bottom = 8.dp),
    )
}

@Composable
private fun Caption(text: String) {
    Text(text = text, color = SecondaryText, fontSize = 12.sp, modifier = Modifier.padding(top = 6.dp))
}

@Composable
private fun ReadOnlyRow(label: String, value: String) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(label, color = PrimaryText, fontSize = 15.sp)
        Text(value, color = SecondaryText, fontSize = 15.sp)
    }
}

@Composable
private fun ToggleRow(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    val colors = LocalNostrVaultColors.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
    ) {
        Text(label, color = PrimaryText, fontSize = 15.sp, modifier = Modifier.weight(1f))
        Switch(
            checked = checked,
            onCheckedChange = onChange,
            colors = SwitchDefaults.colors(
                checkedThumbColor = PrimaryText,
                checkedTrackColor = colors.primary,
            ),
        )
    }
}

@Composable
private fun StepperRow(label: String, value: Int, range: IntRange, step: Int, onChange: (Int) -> Unit) {
    val colors = LocalNostrVaultColors.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
    ) {
        Text("$label: $value", color = PrimaryText, fontSize = 15.sp, modifier = Modifier.weight(1f))
        IconButton(
            onClick = { onChange((value - step).coerceAtLeast(range.first)) },
            enabled = value > range.first,
        ) { Text("−", color = colors.primary, fontSize = 20.sp) }
        IconButton(
            onClick = { onChange((value + step).coerceAtMost(range.last)) },
            enabled = value < range.last,
        ) { Text("+", color = colors.primary, fontSize = 20.sp) }
    }
}

@Composable
private fun <T> PickerRow(label: String, options: List<Pair<T, String>>, selected: T, onSelect: (T) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    val selectedLabel = options.firstOrNull { it.first == selected }?.second ?: selected.toString()
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
    ) {
        Text(label, color = PrimaryText, fontSize = 15.sp, modifier = Modifier.weight(1f))
        Box {
            Text(
                text = selectedLabel,
                color = LocalNostrVaultColors.current.primary,
                fontSize = 15.sp,
                modifier = Modifier.clickable { expanded = true }.padding(8.dp),
            )
            DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                options.forEach { (value, text) ->
                    DropdownMenuItem(
                        text = { Text(text) },
                        onClick = { onSelect(value); expanded = false },
                    )
                }
            }
        }
    }
}
