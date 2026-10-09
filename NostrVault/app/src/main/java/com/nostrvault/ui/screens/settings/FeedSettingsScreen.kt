package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.service.FeedService
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import javax.inject.Inject

/**
 * Settings > Feed: what the feed shows (iOS FeedSettingsView), where it reads
 * from, and a reload for when it goes wrong. The switches are the same values
 * the feed's own filter buttons flip, so changing one here changes it there.
 */
@HiltViewModel
class FeedSettingsViewModel @Inject constructor(
    private val configStore: ConfigStore,
    private val feedService: FeedService,
) : ViewModel() {

    val showReposts: StateFlow<Boolean> = feedService.showReposts
    val showReplies: StateFlow<Boolean> = feedService.showReplies
    val isLoadingFeed: StateFlow<Boolean> = feedService.isLoadingFeed

    val autoLoadNewPosts: StateFlow<Boolean> = configStore.config
        .map { it.autoLoadNewPosts }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), configStore.config.value.autoLoadNewPosts)

    fun setShowReposts(on: Boolean) = feedService.setShowReposts(on)
    fun setShowReplies(on: Boolean) = feedService.setShowReplies(on)
    fun setAutoLoadNewPosts(on: Boolean) = configStore.update { it.copy(autoLoadNewPosts = on) }

    /** Drops the in-memory feed and fetches it again (forceReload refreshes itself). */
    fun reloadFeed() = feedService.forceReload()
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FeedSettingsScreen(
    onBack: () -> Unit,
    onOpenRelays: () -> Unit,
    viewModel: FeedSettingsViewModel = hiltViewModel(),
) {
    val showReposts by viewModel.showReposts.collectAsState()
    val showReplies by viewModel.showReplies.collectAsState()
    val autoLoadNewPosts by viewModel.autoLoadNewPosts.collectAsState()
    val isLoadingFeed by viewModel.isLoadingFeed.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Feed") },
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
            // ── What You See ─────────────────────────────────────
            GroupHeader("What You See")
            Surface(shape = RoundedCornerShape(12.dp), color = SecondaryGroupedBg, modifier = Modifier.fillMaxWidth()) {
                Column {
                    FeedToggle("Show Reposts", SettingsHelp.FEED_REPOSTS.text, showReposts, viewModel::setShowReposts)
                    GroupDivider()
                    FeedToggle("Show Replies", SettingsHelp.FEED_REPLIES.text, showReplies, viewModel::setShowReplies)
                    GroupDivider()
                    FeedToggle("Auto-Load New Posts", SettingsHelp.FEED_AUTO_LOAD.text, autoLoadNewPosts, viewModel::setAutoLoadNewPosts)
                }
            }

            Spacer(Modifier.height(24.dp))

            // ── Feed relays ──────────────────────────────────────
            Surface(shape = RoundedCornerShape(12.dp), color = SecondaryGroupedBg, modifier = Modifier.fillMaxWidth()) {
                GroupRow(icon = NostrVaultIcons.Relay, title = "Feed relays", onClick = onOpenRelays) {
                    Icon(
                        imageVector = NostrVaultIcons.Navigate,
                        contentDescription = null,
                        tint = TertiaryText,
                        modifier = Modifier.size(16.dp),
                    )
                }
            }
            GroupFooter("Your feed reads from the relays marked Read.")

            Spacer(Modifier.height(24.dp))

            // ── Troubleshooting ──────────────────────────────────
            GroupHeader("Troubleshooting")
            Surface(shape = RoundedCornerShape(12.dp), color = SecondaryGroupedBg, modifier = Modifier.fillMaxWidth()) {
                GroupRow(
                    icon = NostrVaultIcons.Refresh,
                    title = "Reload Feed",
                    titleColor = LocalNostrVaultColors.current.primary,
                    enabled = !isLoadingFeed,
                    onClick = viewModel::reloadFeed,
                ) {
                    if (isLoadingFeed) {
                        CircularProgressIndicator(
                            strokeWidth = 2.dp,
                            color = SecondaryText,
                            modifier = Modifier.size(16.dp),
                        )
                    }
                }
            }
            GroupFooter("Clears the posts loaded on this device and loads your feed again from its relays. To check for new posts, pull down on the feed.")
        }
    }
}

@Composable
private fun GroupHeader(title: String) {
    Text(
        text = title,
        color = SecondaryText,
        fontSize = 13.sp,
        fontWeight = FontWeight.SemiBold,
        modifier = Modifier.padding(bottom = 8.dp),
    )
}

@Composable
private fun GroupFooter(text: String) {
    Text(
        text = text,
        color = TertiaryText,
        fontSize = 12.sp,
        modifier = Modifier.padding(start = 4.dp, top = 6.dp),
    )
}

@Composable
private fun GroupDivider() = HorizontalDivider(color = TertiaryGroupedBg, thickness = 0.5.dp)

@Composable
private fun FeedToggle(
    title: String,
    subtitle: String,
    checked: Boolean,
    onToggle: (Boolean) -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 10.dp),
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(title, color = PrimaryText, fontSize = 15.sp)
            Text(subtitle, color = SecondaryText, fontSize = 12.sp)
        }
        Switch(
            checked = checked,
            onCheckedChange = onToggle,
            colors = SwitchDefaults.colors(
                checkedThumbColor = PrimaryText,
                checkedTrackColor = LocalNostrVaultColors.current.primary,
            ),
        )
    }
}

/** A tappable row in a group: icon, title, and whatever trails it. */
@Composable
private fun GroupRow(
    icon: ImageVector,
    title: String,
    onClick: () -> Unit,
    titleColor: androidx.compose.ui.graphics.Color = PrimaryText,
    enabled: Boolean = true,
    trailing: @Composable () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 14.dp),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = LocalNostrVaultColors.current.primary,
            modifier = Modifier.size(20.dp),
        )
        Spacer(Modifier.width(12.dp))
        Text(title, color = titleColor, fontSize = 15.sp, modifier = Modifier.weight(1f))
        trailing()
    }
}
