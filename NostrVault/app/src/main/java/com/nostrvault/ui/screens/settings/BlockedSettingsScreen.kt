package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.relay.HavenConfig
import com.nostrvault.service.NostrService
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.StateFlow
import javax.inject.Inject

/**
 * Blocked / slowed-down accounts settings.
 * Port of iOS BlockedSettingsView: block by npub (published as a NIP-51 kind-10000
 * mute list), unblock, and throttle ("slow down") an account to a max number of
 * visible posts (local-only, never published).
 */
@HiltViewModel
class BlockedSettingsViewModel @Inject constructor(
    private val configStore: ConfigStore,
    private val nostrService: NostrService,
) : ViewModel() {
    val config: StateFlow<HavenConfig> = configStore.config
    val profiles: StateFlow<Map<String, FeedProfile>> = nostrService.profiles

    fun profileFor(npub: String): FeedProfile? =
        nostrService.npubToHex(npub)?.let { profiles.value[it] }

    fun hexFor(npub: String): String = nostrService.npubToHex(npub) ?: ""

    /** Fetch metadata for the given npubs so names/avatars render. */
    fun ensureProfiles(npubs: List<String>) {
        val hexes = npubs.mapNotNull { nostrService.npubToHex(it) }
        if (hexes.isNotEmpty()) nostrService.fetchMissingProfiles(hexes)
    }

    fun block(npub: String) {
        configStore.blockProfile(npub)
        publishMuteList()
    }

    fun unblock(npub: String) {
        configStore.unblockProfile(npub)
        publishMuteList()
    }

    fun throttle(npub: String, maxPosts: Int) = configStore.throttleProfile(npub, maxPosts)

    fun unthrottle(npub: String) = configStore.unthrottleProfile(npub)

    private fun publishMuteList() {
        val cfg = configStore.config.value
        // The list being published is the ACTIVE account's, so it is signed as
        // that account — labelling it the owner's overwrote the owner's kind 10000.
        nostrService.publishMuteList(cfg.activeOrOwnerNpub(), cfg.blockedForActiveAccount())
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BlockedSettingsScreen(
    onBack: () -> Unit,
    viewModel: BlockedSettingsViewModel = hiltViewModel(),
) {
    val config by viewModel.config.collectAsState()
    // Recompose names/avatars as profiles arrive.
    val profiles by viewModel.profiles.collectAsState()
    val colors = LocalNostrVaultColors.current

    val blocked = config.blockedForActiveAccount()
    val throttled = config.throttledForActiveAccount().entries.sortedBy { it.key }

    LaunchedEffect(blocked, throttled) {
        viewModel.ensureProfiles(blocked + throttled.map { it.key })
    }

    var input by remember { mutableStateOf("") }
    val canBlock = input.trim().startsWith("npub1")

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Blocked") },
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
            // ── Block Profile ─────────────────────────────────────
            SectionLabel("Block Profile")
            Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(
                    value = input,
                    onValueChange = { input = it },
                    placeholder = { Text("npub1...") },
                    singleLine = true,
                    modifier = Modifier.weight(1f),
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedTextColor = PrimaryText,
                        unfocusedTextColor = PrimaryText,
                        cursorColor = colors.primary,
                        focusedBorderColor = colors.primary,
                    ),
                )
                Spacer(Modifier.width(8.dp))
                Button(
                    onClick = {
                        viewModel.block(input.trim())
                        input = ""
                    },
                    enabled = canBlock,
                    colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
                ) { Text("Block") }
            }
            Text(
                text = "Enter an npub to block it. Blocked profiles are hidden from your feed.",
                color = SecondaryText,
                fontSize = 12.sp,
                modifier = Modifier.padding(top = 6.dp),
            )

            Spacer(Modifier.height(24.dp))

            // ── Blocked Accounts ──────────────────────────────────
            SectionLabel("Blocked Accounts")
            if (blocked.isEmpty()) {
                EmptyRow("No blocked accounts.")
            } else {
                blocked.forEach { npub ->
                    val profile = viewModel.profileFor(npub)
                    AccountRow(
                        npub = npub,
                        hex = viewModel.hexFor(npub),
                        displayName = profile?.bestName ?: (npub.take(12) + "..."),
                        pictureURL = profile?.pictureURL,
                        secondaryLine = npub,
                    ) {
                        TextButton(onClick = { viewModel.unblock(npub) }) {
                            Text("Unblock", color = ErrorRed)
                        }
                    }
                }
            }

            Spacer(Modifier.height(24.dp))

            // ── Slowed Down ───────────────────────────────────────
            SectionLabel("Slowed Down")
            if (throttled.isEmpty()) {
                EmptyRow("No slowed-down accounts.")
            } else {
                throttled.forEach { (npub, maxPosts) ->
                    val profile = viewModel.profileFor(npub)
                    AccountRow(
                        npub = npub,
                        hex = viewModel.hexFor(npub),
                        displayName = profile?.bestName ?: (npub.take(12) + "..."),
                        pictureURL = profile?.pictureURL,
                        secondaryLine = "Max $maxPosts post${if (maxPosts == 1) "" else "s"} visible",
                    ) {
                        Stepper(
                            value = maxPosts,
                            range = 1..20,
                            onChange = { viewModel.throttle(npub, it) },
                        )
                        IconButton(onClick = { viewModel.unthrottle(npub) }) {
                            Icon(NostrVaultIcons.Dismiss, contentDescription = "Remove", tint = ErrorRed)
                        }
                    }
                }
            }
            Text(
                text = "Slowed-down accounts have a limit on how many of their posts appear " +
                    "in your feed at once.",
                color = SecondaryText,
                fontSize = 12.sp,
                modifier = Modifier.padding(top = 6.dp),
            )

            Spacer(Modifier.height(32.dp))
        }
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
private fun EmptyRow(text: String) {
    Text(text = text, color = TertiaryText, fontSize = 14.sp, modifier = Modifier.padding(vertical = 4.dp))
}

@Composable
private fun AccountRow(
    npub: String,
    hex: String,
    displayName: String,
    pictureURL: String?,
    secondaryLine: String,
    trailing: @Composable RowScope.() -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 6.dp),
    ) {
        AvatarImage(url = pictureURL, pubkey = hex, size = 32.dp, displayName = displayName)
        Spacer(Modifier.width(10.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(displayName, color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
            Text(
                secondaryLine,
                color = SecondaryText,
                fontSize = 11.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        trailing()
    }
}

@Composable
private fun Stepper(value: Int, range: IntRange, onChange: (Int) -> Unit) {
    val colors = LocalNostrVaultColors.current
    Row(verticalAlignment = Alignment.CenterVertically) {
        IconButton(
            onClick = { if (value > range.first) onChange(value - 1) },
            enabled = value > range.first,
        ) { Text("−", color = colors.primary, fontSize = 20.sp) }
        Text("$value", color = PrimaryText, fontSize = 15.sp, modifier = Modifier.widthIn(min = 20.dp))
        IconButton(
            onClick = { if (value < range.last) onChange(value + 1) },
            enabled = value < range.last,
        ) { Text("+", color = colors.primary, fontSize = 20.sp) }
    }
}
