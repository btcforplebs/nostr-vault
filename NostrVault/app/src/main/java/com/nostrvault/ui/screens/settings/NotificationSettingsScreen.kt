package com.nostrvault.ui.screens.settings

import android.content.Context
import android.media.AudioAttributes
import android.media.RingtoneManager
import androidx.compose.foundation.clickable
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
import com.nostrvault.service.LocalNotificationService
import com.nostrvault.service.NostrService
import com.nostrvault.service.NotificationSound
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.StateFlow
import javax.inject.Inject

@HiltViewModel
class NotificationSettingsViewModel @Inject constructor(
    @ApplicationContext private val context: Context,
    private val configStore: ConfigStore,
    private val nostrService: NostrService,
    private val localNotifier: LocalNotificationService,
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

    fun setFeedNotifications(on: Boolean) {
        configStore.update { it.copy(enableFeedNotifications = on) }
    }

    /**
     * Picks the sound and moves notifications to its channel straight away
     * (a channel's sound can't change), then plays it, as iOS previews it.
     */
    fun setSound(sound: NotificationSound) {
        configStore.update { it.copy(notificationSoundName = sound.displayName) }
        localNotifier.ensureChannel()
        val uri = localNotifier.soundUri(sound)
        // Best-effort preview: a failed play shouldn't block picking the sound.
        runCatching {
            RingtoneManager.getRingtone(context, uri)?.apply {
                audioAttributes = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
                play()
            }
        }
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
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.weight(1f)) {
                    Text("Notifications", color = PrimaryText, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                    InfoButton(SettingsHelp.NOTIFY_ENABLE)
                }
                Switch(
                    checked = enabled,
                    onCheckedChange = viewModel::toggleEnabled,
                    colors = SwitchDefaults.colors(checkedThumbColor = PrimaryText, checkedTrackColor = colors.primary),
                )
            }

            Spacer(Modifier.height(16.dp))

            // One summary when people you follow posted while you were away (iOS).
            if (enabled) {
                Surface(shape = RoundedCornerShape(12.dp), color = SecondaryGroupedBg, modifier = Modifier.fillMaxWidth()) {
                    NotificationToggle(
                        "New Notes in Your Feed",
                        null,
                        config.enableFeedNotifications,
                        enabled,
                        help = SettingsHelp.NOTIFY_FEED_NOTES,
                        onToggle = viewModel::setFeedNotifications,
                    )
                }
                Spacer(Modifier.height(16.dp))
            }

            // Sound (iOS NotificationSoundSection), shown with the rest of the
            // enabled-only settings as on iOS.
            if (enabled) {
                Text("Sound", color = SecondaryText, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(bottom = 8.dp))
                Surface(shape = RoundedCornerShape(12.dp), color = SecondaryGroupedBg, modifier = Modifier.fillMaxWidth()) {
                    SoundPicker(NotificationSound.fromName(config.notificationSoundName), viewModel::setSound)
                }
                Spacer(Modifier.height(16.dp))
            }

            Spacer(Modifier.height(8.dp))

            // Per-account notification preferences
            accounts.forEach { npub ->
                val isOwner = npub == config.ownerNpub
                val name = viewModel.profileFor(npub)?.bestName ?: if (isOwner) "Owner" else npub.take(12) + "..."
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 8.dp, bottom = 8.dp)) {
                    AvatarImage(url = viewModel.profileFor(npub)?.pictureURL, pubkey = viewModel.hexFor(npub), size = 28.dp, displayName = name)
                    Spacer(Modifier.width(8.dp))
                    Text(name, color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                    InfoButton(SettingsHelp.NOTIFY_PER_ACCOUNT)
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
                        if (!config.zapsOnlyMode) {
                            Divider()
                            NotificationToggle("Reactions", "Likes and reactions to your notes", prefs.reactions, enabled) {
                                viewModel.setPref(npub) { p -> p.copy(reactions = it) }
                            }
                        }
                        Divider()
                        NotificationToggle("Reposts", "When someone reposts your notes", prefs.reposts, enabled) {
                            viewModel.setPref(npub) { p -> p.copy(reposts = it) }
                        }
                        Divider()
                        NotificationToggle("New Followers", "When someone new follows you", prefs.follows, enabled) {
                            viewModel.setPref(npub) { p -> p.copy(follows = it) }
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
private fun SoundPicker(selected: NotificationSound, onSelect: (NotificationSound) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable { expanded = true }
            .padding(horizontal = 16.dp, vertical = 14.dp),
    ) {
        Text("Sound", color = PrimaryText, fontSize = 15.sp, modifier = Modifier.weight(1f))
        Box {
            Text(selected.displayName, color = LocalNostrVaultColors.current.primary, fontSize = 15.sp)
            DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                NotificationSound.entries.forEach { sound ->
                    DropdownMenuItem(
                        text = { Text(sound.displayName) },
                        trailingIcon = if (sound == selected) {
                            { Icon(NostrVaultIcons.Check, contentDescription = null) }
                        } else {
                            null
                        },
                        // Re-picking the current sound replays it as a preview.
                        onClick = { onSelect(sound); expanded = false },
                    )
                }
            }
        }
    }
}

@Composable
private fun Divider() = HorizontalDivider(color = TertiaryGroupedBg, thickness = 0.5.dp)

@Composable
private fun NotificationToggle(
    title: String,
    subtitle: String?,
    checked: Boolean,
    enabled: Boolean,
    help: SettingsHelp? = null,
    onToggle: (Boolean) -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = if (subtitle == null) 6.dp else 10.dp),
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(title, color = PrimaryText, fontSize = 15.sp)
                if (help != null) InfoButton(help)
            }
            if (subtitle != null) Text(subtitle, color = SecondaryText, fontSize = 12.sp)
        }
        Switch(
            checked = checked,
            onCheckedChange = onToggle,
            enabled = enabled,
            colors = SwitchDefaults.colors(checkedThumbColor = PrimaryText, checkedTrackColor = colors.primary),
        )
    }
}
