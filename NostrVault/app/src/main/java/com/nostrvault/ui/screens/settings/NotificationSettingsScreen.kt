package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.HavenConfig
import com.nostrvault.relay.PushPrefs
import com.nostrvault.service.NostrService
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.StateFlow
import javax.inject.Inject

@HiltViewModel
class NotificationSettingsViewModel @Inject constructor(
    private val configStore: ConfigStore,
    private val nostrService: NostrService,
) : ViewModel() {
    val config: StateFlow<HavenConfig> = configStore.config
    val profiles: StateFlow<Map<String, FeedProfile>> = nostrService.profiles

    fun hexFor(npub: String): String = HavenBridge.decodeNpub(npub) ?: ""
    fun profileFor(npub: String): FeedProfile? = profiles.value[hexFor(npub)]

    fun ensureProfiles(npubs: List<String>) {
        val hexes = npubs.mapNotNull { HavenBridge.decodeNpub(it) }
        if (hexes.isNotEmpty()) nostrService.fetchMissingProfiles(hexes)
    }

    // Android raises notifications locally from the embedded relay (no push
    // server). This just flips the master enable flag that LocalNotificationService
    // checks before posting.
    fun toggleEnabled(on: Boolean) {
        configStore.update { it.copy(enablePushNotifications = on) }
    }

    fun setPref(npub: String, transform: (PushPrefs) -> PushPrefs) {
        configStore.update { cfg ->
            cfg.copy(pushPrefsPerAccount = cfg.pushPrefsPerAccount + (npub to transform(cfg.pushPrefsFor(npub))))
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NotificationSettingsScreen(
    onBack: () -> Unit,
    viewModel: NotificationSettingsViewModel = hiltViewModel(),
) {
    val config by viewModel.config.collectAsState()
    val profiles by viewModel.profiles.collectAsState()
    val colors = LocalNostrVaultColors.current
    val enabled = config.enablePushNotifications
    val accounts = config.allAccountNpubs()

    LaunchedEffect(accounts) { viewModel.ensureProfiles(accounts) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Push Notifications") },
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
            // Master toggle
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.weight(1f)) {
                    Text("Enable Push Notifications", color = PrimaryText, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                    Text("Receive notifications when the app is closed", color = SecondaryText, fontSize = 13.sp)
                }
                Switch(
                    checked = enabled,
                    onCheckedChange = viewModel::toggleEnabled,
                    colors = SwitchDefaults.colors(checkedThumbColor = PrimaryText, checkedTrackColor = colors.primary),
                )
            }

            Spacer(Modifier.height(24.dp))

            // Per-account notification preferences
            accounts.forEach { npub ->
                val isOwner = npub == config.ownerNpub
                val name = viewModel.profileFor(npub)?.bestName ?: if (isOwner) "Owner" else npub.take(12) + "..."
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 8.dp, bottom = 8.dp)) {
                    AvatarImage(url = viewModel.profileFor(npub)?.pictureURL, pubkey = viewModel.hexFor(npub), size = 28.dp, displayName = name)
                    Spacer(Modifier.width(8.dp))
                    Text(name, color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                }
                val prefs = config.pushPrefsFor(npub)
                Surface(shape = RoundedCornerShape(12.dp), color = SecondaryGroupedBg, modifier = Modifier.fillMaxWidth()) {
                    Column {
                        NotificationToggle("Mentions", "When someone mentions you in a note", prefs.mentions, enabled) {
                            viewModel.setPref(npub) { p -> p.copy(mentions = it) }
                        }
                        Divider()
                        NotificationToggle("Replies", "Replies to your notes", prefs.replies, enabled) {
                            viewModel.setPref(npub) { p -> p.copy(replies = it) }
                        }
                        Divider()
                        NotificationToggle("Direct Messages", "New DMs from contacts", prefs.dms, enabled) {
                            viewModel.setPref(npub) { p -> p.copy(dms = it) }
                        }
                        Divider()
                        NotificationToggle("Zaps", "When someone zaps your notes", prefs.zaps, enabled) {
                            viewModel.setPref(npub) { p -> p.copy(zaps = it) }
                        }
                        Divider()
                        NotificationToggle("Reactions", "Likes and reactions to your notes", prefs.reactions, enabled) {
                            viewModel.setPref(npub) { p -> p.copy(reactions = it) }
                        }
                        Divider()
                        NotificationToggle("Reposts", "When someone reposts your notes", prefs.reposts, enabled) {
                            viewModel.setPref(npub) { p -> p.copy(reposts = it) }
                        }
                    }
                }
                Spacer(Modifier.height(16.dp))
            }

            Text(
                text = "Notifications are generated on-device by the relay running in the background — " +
                    "no push server or external service is involved. Your events never leave your phone.",
                color = TertiaryText,
                fontSize = 12.sp,
            )
            Spacer(Modifier.height(16.dp))
        }
    }
}

@Composable
private fun Divider() = HorizontalDivider(color = TertiaryGroupedBg, thickness = 0.5.dp)

@Composable
private fun NotificationToggle(
    title: String,
    subtitle: String,
    checked: Boolean,
    enabled: Boolean,
    onToggle: (Boolean) -> Unit,
) {
    val colors = LocalNostrVaultColors.current
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
            enabled = enabled,
            colors = SwitchDefaults.colors(checkedThumbColor = PrimaryText, checkedTrackColor = colors.primary),
        )
    }
}
