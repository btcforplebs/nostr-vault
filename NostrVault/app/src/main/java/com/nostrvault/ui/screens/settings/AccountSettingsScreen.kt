package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.theme.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AccountSettingsScreen(
    onBack: () -> Unit,
    viewModel: AccountSettingsViewModel = hiltViewModel(),
) {
    val config by viewModel.config.collectAsState()
    val profiles by viewModel.profiles.collectAsState()
    val nip46Connected by viewModel.nip46Connected.collectAsState()
    val keysChanged by viewModel.keysChanged.collectAsState()
    val colors = LocalNostrVaultColors.current

    val accounts = config.allAccountNpubs()
    val activeNpub = config.activeOrOwnerNpub()
    var selected by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(accounts) { viewModel.ensureProfiles(accounts) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Accounts & Keys") },
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
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("ACCOUNTS", color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 1.sp)
                InfoButton(SettingsHelp.ACCOUNT_ACCOUNTS)
            }
            accounts.forEach { npub ->
                val isOwner = npub == config.ownerNpub
                val isActive = npub == activeNpub
                AccountRow(
                    npub = npub,
                    hex = viewModel.hexFor(npub),
                    displayName = viewModel.profileFor(npub)?.bestName
                        ?: if (isOwner) "Owner" else npub.take(12) + "...",
                    pictureURL = viewModel.profileFor(npub)?.pictureURL,
                    mode = config.signingMode(npub),
                    hasBunker = config.bunkerConfig(npub) != null,
                    isOwner = isOwner,
                    isActive = isActive,
                    connected = isActive && nip46Connected,
                    expanded = selected == npub,
                    onClick = { selected = if (selected == npub) null else npub },
                )
                if (selected == npub) {
                    AccountDetail(
                        npub = npub,
                        cfg = config,
                        isOwner = isOwner,
                        isActive = isActive,
                        hasLocalKey = remember(config, keysChanged) { viewModel.hasLocalKey(npub, config) },
                        viewModel = viewModel,
                    )
                }
                HorizontalDivider(color = TertiaryGroupedBg)
            }

            Spacer(Modifier.height(20.dp))
            AddAccountSection(viewModel)

            Spacer(Modifier.height(32.dp))
        }
    }
}

@Composable
private fun AccountRow(
    npub: String,
    hex: String,
    displayName: String,
    pictureURL: String?,
    mode: String,
    hasBunker: Boolean,
    isOwner: Boolean,
    isActive: Boolean,
    connected: Boolean,
    expanded: Boolean,
    onClick: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(vertical = 10.dp),
    ) {
        AvatarImage(url = pictureURL, pubkey = hex, size = 40.dp, displayName = displayName)
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(displayName, color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                if (isOwner) {
                    Spacer(Modifier.width(6.dp))
                    Badge2("Owner", colorPrimaryFor(mode = "owner"))
                }
            }
            val modeLabel = when {
                hasBunker || mode == "nip46" -> "Remote Signer"
                mode == "amber" -> "Amber"
                else -> "Local Key"
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(modeLabel, color = SecondaryText, fontSize = 12.sp)
                if ((hasBunker || mode == "nip46") && isActive) {
                    Spacer(Modifier.width(6.dp))
                    Box(
                        modifier = Modifier
                            .size(8.dp)
                            .clip(RoundedCornerShape(4.dp))
                            .background(if (connected) Color(0xFF4CAF50) else ErrorRed),
                    )
                }
            }
        }
        if (isActive) {
            Icon(NostrVaultIcons.Check, contentDescription = "Active", tint = LocalNostrVaultColors.current.primary, modifier = Modifier.size(20.dp))
        }
    }
}

@Composable
private fun Badge2(text: String, color: Color) {
    Surface(color = color.copy(alpha = 0.15f), shape = RoundedCornerShape(6.dp)) {
        Text(
            text,
            color = color,
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
        )
    }
}

private fun colorPrimaryFor(mode: String): Color = when (mode) {
    "owner" -> Color(0xFF9C27B0)
    "amber" -> Color(0xFF4CAF50)
    "nip46" -> Color(0xFF2196F3)
    else -> Color(0xFFF59E0B)
}
