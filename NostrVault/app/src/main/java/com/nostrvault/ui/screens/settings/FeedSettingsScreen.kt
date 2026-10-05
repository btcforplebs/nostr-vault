package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenConfig
import com.nostrvault.service.FeedService
import com.nostrvault.ui.navigation.Screen
import com.nostrvault.ui.theme.NostrVaultIcons
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.StateFlow
import javax.inject.Inject

@HiltViewModel
class FeedSettingsViewModel @Inject constructor(
    private val configStore: ConfigStore,
    private val feedService: FeedService,
) : ViewModel() {
    val config: StateFlow<HavenConfig> = configStore.config
    // The same switches as the feed toolbar menu, so the two never disagree.
    val showReposts: StateFlow<Boolean> = feedService.showReposts
    val showReplies: StateFlow<Boolean> = feedService.showReplies

    fun setShowReposts(v: Boolean) = feedService.setShowReposts(v)
    fun setShowReplies(v: Boolean) = feedService.setShowReplies(v)
    fun setAutoLoadNewPosts(v: Boolean) = configStore.update { it.copy(autoLoadNewPosts = v) }
}

/**
 * "Feed" (iOS `FeedSettingsView`): what the feed shows, and the relays it
 * reads and searches. iOS edits both relay lists inline; here they keep
 * their own pages, one tap down.
 */
@Composable
fun FeedSettingsScreen(
    onNavigate: (Screen) -> Unit,
    onBack: () -> Unit,
    viewModel: FeedSettingsViewModel = hiltViewModel(),
) {
    val config by viewModel.config.collectAsState()
    val showReposts by viewModel.showReposts.collectAsState()
    val showReplies by viewModel.showReplies.collectAsState()

    SettingsPage(title = "Feed", onBack = onBack) {
        SettingsSectionLabel("What You See")
        SettingsToggleRow("Show Reposts", showReposts, SettingsHelp.FEED_REPOSTS, onChange = viewModel::setShowReposts)
        SettingsToggleRow("Show Replies", showReplies, SettingsHelp.FEED_REPLIES, onChange = viewModel::setShowReplies)
        SettingsToggleRow("Auto-Load New Posts", config.autoLoadNewPosts, SettingsHelp.FEED_AUTO_LOAD, onChange = viewModel::setAutoLoadNewPosts)

        Spacer(Modifier.height(20.dp))

        SettingsSectionLabel("Relays")
        // SettingsItem carries its own 16dp side padding; cancel the page's.
        Column(Modifier.bleedHorizontal(16.dp)) {
            SettingsItem(
                icon = NostrVaultIcons.Feed,
                title = "Feed Relays",
                subtitle = "Where your feed is read from",
                onClick = { onNavigate(Screen.RelayListEditor) },
            )
            SettingsItem(
                icon = NostrVaultIcons.Search,
                title = "Search Relays",
                subtitle = "NIP-50 relays used by Global search",
                onClick = { onNavigate(Screen.SearchRelaySettings) },
            )
        }
    }
}
