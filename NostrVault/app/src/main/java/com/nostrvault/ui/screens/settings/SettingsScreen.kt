package com.nostrvault.ui.screens.settings

import android.content.Intent
import android.net.Uri
import com.nostrvault.BuildConfig
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PowerSettingsNew
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import com.nostrvault.ui.navigation.Screen
import com.nostrvault.ui.theme.*

/** App version string shown in the About section (mirrors iOS appVersion). */
private val APP_VERSION = BuildConfig.VERSION_NAME
private val APP_BUILD = BuildConfig.VERSION_CODE

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
    viewModel: AdvancedSettingsViewModel = hiltViewModel(),
) {
    val config by viewModel.config.collectAsState()
    Scaffold(
        topBar = {
            // iPhone opens Settings as a sheet: inline title, "Close" on the left.
            CenterAlignedTopAppBar(
                title = { Text("Settings", fontSize = 17.sp, fontWeight = FontWeight.SemiBold) },
                navigationIcon = {
                    TextButton(onClick = onBack) {
                        Text("Close", color = LocalNostrVaultColors.current.primary, fontSize = 17.sp)
                    }
                },
                colors = TopAppBarDefaults.centerAlignedTopAppBarColors(
                    containerColor = WindowBackground,
                    titleContentColor = PrimaryText,
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
            settingsTopItems(config).forEach { top ->
                when (top) {
                    SettingsTopItem.SETUP_INCOMPLETE -> item {
                        SetupIncompleteBanner(onClick = { onNavigate(SETUP_INCOMPLETE_DESTINATION) })
                    }
                    // Is the relay on this phone running, and where (iOS RelayStatusCard).
                    SettingsTopItem.RELAY_STATUS -> item { RelayStatusCard() }
                }
            }

            SETTINGS_GROUPS.forEach { group ->
                item { SettingsSectionHeader(group.title) }
                // One rounded card per group, as the iPhone's inset-grouped list.
                item(key = group.title) {
                    SettingsCard {
                        group.rows.forEachIndexed { index, row ->
                            if (index > 0) SettingsRowDivider()
                            SettingsItem(
                                icon = row.icon,
                                title = row.title,
                                tileColor = row.color,
                                onClick = { onNavigate(row.screen) },
                            )
                        }
                        if (group.title == "Your Vault") {
                            // One switch, so it lives here rather than behind a page
                            // of its own, as on iPhone.
                            SettingsRowDivider()
                            SettingsToggleItem(
                                icon = Icons.Default.PowerSettingsNew,
                                title = "Start Vault Automatically",
                                tileColor = SettingsTile.Green,
                                help = SettingsHelp.RELAY_AUTO_START,
                                checked = config.autoStartRelay,
                                onChange = viewModel::setAutoStartRelay,
                            )
                        }
                    }
                }
            }

            // ── ABOUT ─────────────────────────────────────────────
            item { SettingsSectionHeader("About") }
            item { AboutSection() }

            // Room to scroll the last section above the tab bar (iOS 60pt).
            item { Spacer(Modifier.height(60.dp)) }
        }
    }
}

/** One row of the Settings list: where it goes, and the iPhone tile it wears. */
data class SettingsRow(val title: String, val icon: ImageVector, val color: Color, val screen: Screen)

/** A titled run of rows (iOS SettingsView.groups). */
data class SettingsGroup(val title: String, val rows: List<SettingsRow>)

/** The iPhone tile colours (iOS iconBackgroundColor), not the accent. */
object SettingsTile {
    val Blue = Color(0xFF0A84FF)
    val Red = Color(0xFFFF453A)
    val Teal = Color(0xFF64D2FF)
    val Orange = Color(0xFFFF9F0A)
    val Pink = Color(0xFFFF375F)
    val Purple = Color(0xFFBF5AF2)
    val Indigo = Color(0xFF5E5CE6)
    val Green = Color(0xFF30D158)
    val Gray = Color(0xFF8E8E93)
    val Haven = Color(0xFF8B5CF6)
}

/**
 * The settings grouped by what someone is trying to do, not by which process
 * owns the value. Same groups, order and names as the iPhone list
 * (SettingsView.swift `groups`), so the two can't drift.
 */
val SETTINGS_GROUPS: List<SettingsGroup> = listOf(
    SettingsGroup("Account", listOf(
        SettingsRow("Accounts & Keys", NostrVaultIcons.Accounts, SettingsTile.Blue, Screen.AccountSettings),
        SettingsRow("Blocked", NostrVaultIcons.Blocked, SettingsTile.Red, Screen.BlockedSettings),
        SettingsRow("Recently Deleted", NostrVaultIcons.Delete, SettingsTile.Gray, Screen.RecentlyDeletedSettings),
        SettingsRow("Following Backup", NostrVaultIcons.SettingsFollowingBackup, SettingsTile.Teal, Screen.FollowingBackup),
        SettingsRow("Wallet", NostrVaultIcons.Wallet, SettingsTile.Orange, Screen.WalletSettings),
        SettingsRow("Privacy", NostrVaultIcons.SettingsPrivacy, SettingsTile.Blue, Screen.PrivacySettings),
    )),
    SettingsGroup("Feed & Display", listOf(
        SettingsRow("Feed", NostrVaultIcons.SettingsFeed, SettingsTile.Pink, Screen.FeedSettings),
        SettingsRow("Appearance", NostrVaultIcons.Appearance, SettingsTile.Purple, Screen.AppearanceSettings),
        SettingsRow("Media & Cache", NostrVaultIcons.SettingsMedia, SettingsTile.Indigo, Screen.MediaSettings),
    )),
    SettingsGroup("Notifications", listOf(
        SettingsRow("Notifications", NostrVaultIcons.Notifications, SettingsTile.Red, Screen.NotificationSettings),
    )),
    SettingsGroup("Relays", listOf(
        SettingsRow("Relays", NostrVaultIcons.SettingsRelays, SettingsTile.Haven, Screen.Relays),
        SettingsRow("Media Servers", NostrVaultIcons.SettingsMediaServers, SettingsTile.Green, Screen.BlossomSettings),
    )),
    SettingsGroup("Your Vault", listOf(
        SettingsRow("Home vault sync", NostrVaultIcons.SettingsMacRelay, SettingsTile.Teal, Screen.HavenRelaySettings),
        SettingsRow("Who Can Reach You", NostrVaultIcons.SettingsRelayAccess, SettingsTile.Blue, Screen.RelayAccessSettings),
        SettingsRow("Import Notes", NostrVaultIcons.Import, SettingsTile.Orange, Screen.ImportSettings),
        SettingsRow("Backup & Restore", NostrVaultIcons.SettingsBackup, SettingsTile.Indigo, Screen.BackupSettings),
    )),
    SettingsGroup("Mesh", listOf(
        SettingsRow("Mesh", NostrVaultIcons.SettingsRelays, SettingsTile.Teal, Screen.MeshSettings),
    )),
    SettingsGroup("Help", listOf(
        SettingsRow("Tutorials", NostrVaultIcons.Tutorials, SettingsTile.Purple, Screen.TutorialsSettings),
    )),
    SettingsGroup("Advanced", listOf(
        SettingsRow("Proof of Work", NostrVaultIcons.PoW, SettingsTile.Purple, Screen.PowSettings),
        SettingsRow("Database & Reset", NostrVaultIcons.SettingsDatabase, SettingsTile.Gray, Screen.AdvancedSettings),
        SettingsRow("Bitcoin On-Chain", NostrVaultIcons.Wallet, SettingsTile.Orange, Screen.BitcoinWallet),
        SettingsRow("Logs", NostrVaultIcons.SettingsLogs, SettingsTile.Gray, Screen.LogViewer),
    )),
)

@Composable
private fun AboutSection() {
    val clipboard = LocalClipboardManager.current
    val context = LocalContext.current
    // Centred, with a divider before the support block and before the
    // privacy link, as iOS SettingsView's About section.
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        Text(
            text = "Nostr Vault",
            color = PrimaryText,
            fontSize = 17.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(4.dp))
        Text(
            text = "Version $APP_VERSION ($APP_BUILD)",
            color = SecondaryText,
            fontSize = 12.sp,
        )
        HorizontalDivider(color = SeparatorColor, modifier = Modifier.padding(vertical = 8.dp))
        Text(
            text = "Support & Abuse Reporting",
            color = PrimaryText,
            fontSize = 15.sp,
            fontWeight = FontWeight.Bold,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = "To report objectionable content or abusive users, contact the developer via Nostr",
            color = SecondaryText,
            fontSize = 12.sp,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = DEVELOPER_NPUB,
            color = PrimaryText,
            fontSize = 10.sp,
            fontFamily = FontFamily.Monospace,
            modifier = Modifier
                .clip(RoundedCornerShape(4.dp))
                .background(TertiaryGroupedBg)
                .clickable { clipboard.setText(AnnotatedString(DEVELOPER_NPUB)) }
                .padding(8.dp),
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = "(Tap to copy)",
            color = SecondaryText,
            fontSize = 8.sp,
        )
        HorizontalDivider(color = SeparatorColor, modifier = Modifier.padding(vertical = 8.dp))
        Text(
            text = "Privacy Policy",
            color = LocalNostrVaultColors.current.primary,
            fontSize = 12.sp,
            modifier = Modifier.clickable {
                runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(PRIVACY_POLICY_URL))) }
            },
        )
    }
}

/** The rounded card a group's rows sit in (iOS `.insetGrouped`). */
@Composable
private fun SettingsCard(content: @Composable ColumnScope.() -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(SecondaryGroupedBg),
        content = content,
    )
}

/** Hairline between rows, inset to the text like the iPhone list. */
@Composable
private fun SettingsRowDivider() {
    HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp, modifier = Modifier.padding(start = 58.dp))
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

/** The iPhone tile: a rounded square in the row's colour with a white glyph. */
@Composable
private fun SettingsTileIcon(icon: ImageVector, color: Color) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .size(28.dp)
            .clip(RoundedCornerShape(6.dp))
            .background(color),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = Color.White,
            modifier = Modifier.size(16.dp),
        )
    }
}

@Composable
fun SettingsItem(
    icon: ImageVector,
    title: String,
    tileColor: Color,
    onClick: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 10.dp),
    ) {
        SettingsTileIcon(icon, tileColor)
        Spacer(Modifier.width(14.dp))
        Text(
            text = title,
            color = PrimaryText,
            fontSize = 16.sp,
            modifier = Modifier.weight(1f),
        )
        Icon(
            imageVector = NostrVaultIcons.Navigate,
            contentDescription = null,
            tint = TertiaryText,
            modifier = Modifier.size(16.dp),
        )
    }
}

/** A switch in the list, laid out like the rows around it. */
@Composable
private fun SettingsToggleItem(
    icon: ImageVector,
    title: String,
    tileColor: Color,
    help: SettingsHelp,
    checked: Boolean,
    onChange: (Boolean) -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp),
    ) {
        SettingsTileIcon(icon, tileColor)
        Spacer(Modifier.width(14.dp))
        Text(text = title, color = PrimaryText, fontSize = 16.sp)
        InfoButton(help)
        Spacer(Modifier.weight(1f))
        Switch(
            checked = checked,
            onCheckedChange = onChange,
            colors = SwitchDefaults.colors(
                checkedThumbColor = PrimaryText,
                checkedTrackColor = LocalNostrVaultColors.current.primary,
            ),
        )
    }
}
