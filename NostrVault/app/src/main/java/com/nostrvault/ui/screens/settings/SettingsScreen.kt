package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
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
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.ui.navigation.Screen
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject

/**
 * Main settings screen with grouped navigation items.
 * Port of SettingsView.swift iOS list layout.
 */
@HiltViewModel
class SettingsViewModel @Inject constructor(
    private val configStore: ConfigStore,
) : ViewModel() {
    val config = configStore.config

    fun togglePrefetchAvatars() {
        configStore.update { it.copy(prefetchAvatars = !it.prefetchAvatars) }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    onNavigate: (Screen) -> Unit,
    onBack: () -> Unit,
    viewModel: SettingsViewModel = hiltViewModel(),
) {
    val config by viewModel.config.collectAsState()
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Settings", fontWeight = FontWeight.Bold) },
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
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
        ) {
            // Profile section
            item {
                SettingsSectionHeader("Profile")
            }
            item {
                SettingsItem(
                    icon = NostrVaultIcons.Accounts,
                    title = "Accounts",
                    subtitle = "Manage keypairs and switch accounts",
                    onClick = { onNavigate(Screen.AccountSettings) },
                )
            }
            item {
                SettingsItem(
                    icon = NostrVaultIcons.Blocked,
                    title = "Blocked Users",
                    subtitle = "Manage your block list",
                    onClick = { /* TODO */ },
                )
            }
            item {
                SettingsItem(
                    icon = NostrVaultIcons.Accounts,
                    title = "Following Backup",
                    subtitle = "Snapshots of your following list",
                    onClick = { onNavigate(Screen.FollowingBackup) },
                )
            }
            item {
                SettingsItem(
                    icon = NostrVaultIcons.Edit,
                    title = "Drafts",
                    subtitle = "Unsent notes saved automatically",
                    onClick = { onNavigate(Screen.Drafts) },
                )
            }

            // Appearance section
            item {
                SettingsSectionHeader("Appearance")
            }
            item {
                SettingsItem(
                    icon = NostrVaultIcons.Appearance,
                    title = "Theme & Display",
                    subtitle = "Colors, text size, OLED mode",
                    onClick = { onNavigate(Screen.AppearanceSettings) },
                )
            }

            // Relay section
            item {
                SettingsSectionHeader("Relay Configuration")
            }
            item {
                SettingsItem(
                    icon = NostrVaultIcons.Domain,
                    title = "Haven Relay",
                    subtitle = "Sync notes from your Mac or cloud relay",
                    onClick = { onNavigate(Screen.HavenRelaySettings) },
                )
            }
            item {
                SettingsItem(
                    icon = NostrVaultIcons.Feed,
                    title = "Feed Relays",
                    subtitle = "Configure external relay sources",
                    onClick = { onNavigate(Screen.RelayListEditor) },
                )
            }
            item {
                SettingsItem(
                    icon = NostrVaultIcons.DMs,
                    title = "DM Relays",
                    subtitle = "NIP-17 gift-wrap relay settings",
                    onClick = { onNavigate(Screen.DMRelaySettings) },
                )
            }
            item {
                SettingsItem(
                    icon = NostrVaultIcons.Media,
                    title = "Blossom Servers",
                    subtitle = "Media upload and mirror configuration",
                    onClick = { onNavigate(Screen.BlossomSettings) },
                )
            }

            // System section
            item {
                SettingsSectionHeader("System")
            }
            item {
                SettingsItem(
                    icon = NostrVaultIcons.Blastr,
                    title = "Blastr Broadcasting",
                    subtitle = "Broadcast notes to public relays",
                    onClick = { onNavigate(Screen.BlastrSettings) },
                )
            }
            item {
                SettingsItem(
                    icon = NostrVaultIcons.PoW,
                    title = "Proof of Work",
                    subtitle = "Mining difficulty for anti-spam",
                    onClick = { onNavigate(Screen.PowSettings) },
                )
            }
            item {
                SettingsItem(
                    icon = NostrVaultIcons.Import,
                    title = "Cloud Backup",
                    subtitle = "S3-compatible remote backup",
                    onClick = { onNavigate(Screen.CloudBackupSettings) },
                )
            }
            item {
                SettingsItem(
                    icon = NostrVaultIcons.Notifications,
                    title = "Push Notifications",
                    subtitle = "FCM push server configuration",
                    onClick = { onNavigate(Screen.NotificationSettings) },
                )
            }
            item {
                SettingsItem(
                    icon = NostrVaultIcons.Wallet,
                    title = "Wallet",
                    subtitle = "NWC and Cashu configuration",
                    onClick = { /* TODO */ },
                )
            }
            item {
                SettingsItem(
                    icon = NostrVaultIcons.Logs,
                    title = "Relay Logs",
                    subtitle = "View relay process output",
                    onClick = { onNavigate(Screen.LogViewer) },
                )
            }

            // Performance section
            item {
                SettingsSectionHeader("Performance")
            }
            item {
                SettingsToggleItem(
                    icon = NostrVaultIcons.Media,
                    title = "Prefetch Avatars",
                    subtitle = "Download profile pictures on Wi-Fi for faster scrolling",
                    checked = config.prefetchAvatars,
                    onToggle = viewModel::togglePrefetchAvatars,
                )
            }

            // Version info
            item {
                Spacer(Modifier.height(24.dp))
                Text(
                    text = "Nostr Vault v1.0.0",
                    color = TertiaryText,
                    fontSize = 12.sp,
                    modifier = Modifier.padding(horizontal = 16.dp),
                )
                Spacer(Modifier.height(32.dp))
            }
        }
    }
}

@Composable
private fun SettingsSectionHeader(title: String) {
    Text(
        text = title.uppercase(),
        color = SecondaryText,
        fontSize = 12.sp,
        fontWeight = FontWeight.SemiBold,
        letterSpacing = 1.sp,
        modifier = Modifier.padding(start = 16.dp, top = 24.dp, bottom = 8.dp),
    )
}

@Composable
fun SettingsItem(
    icon: ImageVector,
    title: String,
    subtitle: String? = null,
    onClick: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = LocalNostrVaultColors.current.primary,
            modifier = Modifier.size(22.dp),
        )
        Spacer(Modifier.width(14.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = title,
                color = PrimaryText,
                fontSize = 16.sp,
            )
            if (subtitle != null) {
                Text(
                    text = subtitle,
                    color = SecondaryText,
                    fontSize = 13.sp,
                )
            }
        }
        Icon(
            imageVector = NostrVaultIcons.Navigate,
            contentDescription = null,
            tint = TertiaryText,
            modifier = Modifier.size(16.dp),
        )
    }
}

@Composable
private fun SettingsToggleItem(
    icon: ImageVector,
    title: String,
    subtitle: String? = null,
    checked: Boolean,
    onToggle: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onToggle)
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = LocalNostrVaultColors.current.primary,
            modifier = Modifier.size(22.dp),
        )
        Spacer(Modifier.width(14.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = title,
                color = PrimaryText,
                fontSize = 16.sp,
            )
            if (subtitle != null) {
                Text(
                    text = subtitle,
                    color = SecondaryText,
                    fontSize = 13.sp,
                )
            }
        }
        Switch(
            checked = checked,
            onCheckedChange = { onToggle() },
            colors = SwitchDefaults.colors(
                checkedThumbColor = PrimaryText,
                checkedTrackColor = LocalNostrVaultColors.current.primary,
                uncheckedThumbColor = SecondaryText,
                uncheckedTrackColor = TertiaryGroupedBg,
            ),
        )
    }
}
