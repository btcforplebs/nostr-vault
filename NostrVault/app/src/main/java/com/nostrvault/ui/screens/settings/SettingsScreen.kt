package com.nostrvault.ui.screens.settings

import android.content.Intent
import android.net.Uri
import com.nostrvault.BuildConfig
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.navigation.Screen
import com.nostrvault.ui.theme.*

/** App version string shown in the About section (mirrors iOS appVersion). */
private val APP_VERSION = BuildConfig.VERSION_NAME

/** Developer / abuse-reporting npub (matches iOS SettingsView). */
private const val DEVELOPER_NPUB =
    "npub1vxlhjzeqjjhmqdy4e8sndt8kzklqlnxzew2mtt8mtakvalsckp3qa0gnvx"

/** Privacy policy URL (matches iOS SettingsView). */
private const val PRIVACY_POLICY_URL = "https://nostrvault.app/privacy.html"

/**
 * Main settings screen with grouped navigation items.
 * Port of SettingsView.swift iOS list layout (sections, order and labels mirror iOS).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    onNavigate: (Screen) -> Unit,
    onBack: () -> Unit,
) {
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
            // ── PROFILE ───────────────────────────────────────────
            item { SettingsSectionHeader("Profile") }
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
                    title = "Blocked",
                    subtitle = "Block and slow down accounts",
                    onClick = { onNavigate(Screen.BlockedSettings) },
                )
            }

            // ── APPEARANCE ────────────────────────────────────────
            item { SettingsSectionHeader("Appearance") }
            item {
                SettingsItem(
                    icon = NostrVaultIcons.Appearance,
                    title = "Theme & Display",
                    subtitle = "Colors, text size, OLED mode",
                    onClick = { onNavigate(Screen.AppearanceSettings) },
                )
            }

            // ── RELAY CONFIGURATION ───────────────────────────────
            item { SettingsSectionHeader("Relay Configuration") }
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
                    icon = NostrVaultIcons.Blastr,
                    title = "Blastr",
                    subtitle = "Broadcast notes to public relays",
                    onClick = { onNavigate(Screen.BlastrSettings) },
                )
            }
            item {
                SettingsItem(
                    icon = NostrVaultIcons.Media,
                    title = "Blossom",
                    subtitle = "Media upload and mirror configuration",
                    onClick = { onNavigate(Screen.BlossomSettings) },
                )
            }
            item {
                SettingsItem(
                    icon = NostrVaultIcons.Import,
                    title = "Import",
                    subtitle = "Fetch notes from seed relays",
                    onClick = { onNavigate(Screen.ImportSettings) },
                )
            }
            item {
                SettingsItem(
                    icon = NostrVaultIcons.Backup,
                    title = "Backup",
                    subtitle = "Export and import notes and media",
                    onClick = { onNavigate(Screen.BackupSettings) },
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
                    icon = NostrVaultIcons.Domain,
                    title = "Haven Relay",
                    subtitle = "Sync notes from your Mac or cloud relay",
                    onClick = { onNavigate(Screen.HavenRelaySettings) },
                )
            }
            item {
                SettingsItem(
                    icon = NostrVaultIcons.Domain,
                    title = "Mesh",
                    subtitle = "Broadcast this device's address on the FIPS mesh",
                    onClick = { onNavigate(Screen.MeshSettings) },
                )
            }

            // ── SYSTEM ────────────────────────────────────────────
            item { SettingsSectionHeader("System") }
            item {
                SettingsItem(
                    icon = NostrVaultIcons.Notifications,
                    title = "Push Notifications",
                    subtitle = "Mentions, replies, DMs, zaps and more",
                    onClick = { onNavigate(Screen.NotificationSettings) },
                )
            }
            item {
                SettingsItem(
                    icon = NostrVaultIcons.Wallet,
                    title = "Wallet",
                    subtitle = "NWC, Cashu and Bitcoin",
                    onClick = { onNavigate(Screen.Wallet) },
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
                    icon = NostrVaultIcons.Settings,
                    title = "Advanced",
                    subtitle = "Limits, media, web of trust, reset",
                    onClick = { onNavigate(Screen.AdvancedSettings) },
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

            // ── ABOUT ─────────────────────────────────────────────
            item { SettingsSectionHeader("About") }
            item { AboutSection() }

            item { Spacer(Modifier.height(32.dp)) }
        }
    }
}

@Composable
private fun AboutSection() {
    val clipboard = LocalClipboardManager.current
    val context = LocalContext.current
    Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
        Text(
            text = "Nostr Vault v$APP_VERSION",
            color = PrimaryText,
            fontSize = 15.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(12.dp))
        Text(
            text = "Support & Abuse Reporting",
            color = SecondaryText,
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(4.dp))
        Text(
            text = DEVELOPER_NPUB,
            color = PrimaryText,
            fontSize = 12.sp,
            modifier = Modifier.clickable {
                clipboard.setText(AnnotatedString(DEVELOPER_NPUB))
            },
        )
        Text(
            text = "(Tap to copy)",
            color = TertiaryText,
            fontSize = 11.sp,
        )
        Spacer(Modifier.height(12.dp))
        Text(
            text = "Privacy Policy",
            color = LocalNostrVaultColors.current.primary,
            fontSize = 14.sp,
            modifier = Modifier.clickable {
                context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(PRIVACY_POLICY_URL)))
            },
        )
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
