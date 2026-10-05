package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenConfig
import com.nostrvault.service.MediaCacheService
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.StateFlow
import javax.inject.Inject

/** Cache lifetime options: value (days) -> label. 0 = Never. Same as iOS. */
private val CACHE_TTL_OPTIONS = listOf(
    1 to "1 day", 3 to "3 days", 7 to "7 days", 14 to "14 days", 30 to "30 days", 0 to "Never",
)

@HiltViewModel
class MediaSettingsViewModel @Inject constructor(
    private val configStore: ConfigStore,
    private val mediaCacheService: MediaCacheService,
) : ViewModel() {
    val config: StateFlow<HavenConfig> = configStore.config

    fun setAutoplay(v: Boolean) = configStore.update { it.copy(autoplayVideos = v) }
    fun setPrefetch(v: Boolean) = configStore.update { it.copy(prefetchAvatars = v) }
    fun setDisableMediaCache(v: Boolean) = configStore.update { it.copy(disableMediaCache = v) }
    fun setCacheTTL(v: Int) = configStore.update { it.copy(cacheTTLDays = v) }
    fun clearMediaCache() = mediaCacheService.clearCache()
}

/**
 * How media is played and kept on this device (iOS `MediaSettingsView`).
 * App-side only: none of this reaches the relay, which is why it no longer
 * sits next to the relay's database.
 */
@Composable
fun MediaSettingsScreen(
    onBack: () -> Unit,
    viewModel: MediaSettingsViewModel = hiltViewModel(),
) {
    val config by viewModel.config.collectAsState()
    var confirmClear by remember { mutableStateOf(false) }

    SettingsPage(title = "Media & Cache", onBack = onBack) {
        SettingsSectionLabel("Playback")
        SettingsToggleRow("Autoplay Videos", config.autoplayVideos, SettingsHelp.MEDIA_AUTOPLAY, onChange = viewModel::setAutoplay)
        SettingsToggleRow("Prefetch Profile Pictures", config.prefetchAvatars, SettingsHelp.MEDIA_PREFETCH_AVATARS, onChange = viewModel::setPrefetch)

        Spacer(Modifier.height(20.dp))

        SettingsSectionLabel("Cache")
        SettingsToggleRow("Disable Media Cache", config.disableMediaCache, SettingsHelp.MEDIA_DISABLE_CACHE, onChange = viewModel::setDisableMediaCache)
        SettingsPickerRow(
            label = "Keep Media For",
            options = CACHE_TTL_OPTIONS,
            selected = config.cacheTTLDays,
            help = SettingsHelp.MEDIA_CACHE_T_T_L,
            enabled = !config.disableMediaCache,
            onSelect = viewModel::setCacheTTL,
        )
        TextButton(onClick = { confirmClear = true }) {
            Text("Clear Media Cache", color = ErrorRed)
        }
    }

    if (confirmClear) {
        // Same title, message and buttons as the iOS Media & Cache screen.
        AlertDialog(
            onDismissRequest = { confirmClear = false },
            title = { Text("Clear Media Cache?") },
            text = {
                Text("Removes temporary copies of images and videos. They download again when you view them. Your vault and your Blossom servers are not touched.")
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmClear = false
                    viewModel.clearMediaCache()
                }) { Text("Clear", color = ErrorRed) }
            },
            dismissButton = {
                TextButton(onClick = { confirmClear = false }) { Text("Cancel") }
            },
        )
    }
}
