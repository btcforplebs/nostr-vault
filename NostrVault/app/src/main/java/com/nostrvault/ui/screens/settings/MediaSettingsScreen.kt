package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.nostrvault.ui.screens.dashboard.formatSize
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.WindowBackground

/** Keep Media For options: value (days) -> label (iOS MediaSettingsView). 0 = Never. */
internal val CACHE_TTL_OPTIONS = listOf(
    1 to "1 day", 3 to "3 days", 7 to "7 days", 14 to "14 days", 30 to "30 days", 0 to "Never",
)

/**
 * Media & Cache: how media is played and kept on this phone (iOS
 * MediaSettingsView). App-side only; none of it reaches the relay, which is
 * why it no longer sits in Advanced next to the relay's database.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MediaSettingsScreen(
    onBack: () -> Unit,
    viewModel: AdvancedSettingsViewModel = hiltViewModel(),
) {
    val config by viewModel.config.collectAsState()
    val cacheBytes by viewModel.cacheBytes.collectAsState()
    var confirmClearCache by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { viewModel.measureCache() }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Media & Cache") },
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
            SectionLabel("Playback")
            ToggleRow("Autoplay Videos", config.autoplayVideos, viewModel::setAutoplay, SettingsHelp.MEDIA_AUTOPLAY)
            ToggleRow("Prefetch Profile Pictures", config.prefetchAvatars, viewModel::setPrefetch, SettingsHelp.MEDIA_PREFETCH_AVATARS)

            Spacer(Modifier.height(20.dp))

            SectionLabel("Cache")
            ToggleRow("Disable Media Cache", config.disableMediaCache, viewModel::setDisableMediaCache, SettingsHelp.MEDIA_DISABLE_CACHE)
            PickerRow(
                "Keep Media For",
                CACHE_TTL_OPTIONS,
                config.cacheTTLDays,
                SettingsHelp.MEDIA_CACHE_TTL,
                enabled = !config.disableMediaCache,
            ) { viewModel.setCacheTTL(it) }
            TextButton(onClick = { confirmClearCache = true }, modifier = Modifier.fillMaxWidth()) {
                Text("Clear Media Cache", color = ErrorRed, modifier = Modifier.weight(1f))
                cacheBytes?.let { Text(formatSize(it), color = SecondaryText) }
                InfoButton(SettingsHelp.MEDIA_CLEAR_CACHE)
            }
            // Android only: a Blossom cache app on this phone (no iOS counterpart).
            ToggleRow("Use Local Blossom Cache", config.useLocalBlossomCache, viewModel::setUseLocalBlossomCache)
            Caption(
                "Loads media through a Blossom cache app on this phone, such as Morganite " +
                    "(127.0.0.1:24242), when it is running. Media you have seen once then loads " +
                    "from the phone, offline too. Uploads never go through it."
            )

            Spacer(Modifier.height(32.dp))
        }
    }

    if (confirmClearCache) {
        // Same title, message and buttons as the iOS Media & Cache screen.
        AlertDialog(
            onDismissRequest = { confirmClearCache = false },
            title = { Text("Clear Media Cache?") },
            text = { Text(AdvancedSettingsViewModel.clearMessage(cacheBytes)) },
            confirmButton = {
                TextButton(onClick = {
                    confirmClearCache = false
                    viewModel.clearMediaCache()
                }) { Text("Clear", color = ErrorRed) }
            },
            dismissButton = {
                TextButton(onClick = { confirmClearCache = false }) { Text("Cancel") }
            },
        )
    }
}
