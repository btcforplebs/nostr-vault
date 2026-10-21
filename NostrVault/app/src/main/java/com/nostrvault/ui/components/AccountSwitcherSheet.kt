package com.nostrvault.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.HavenConfig
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryGroupedBg
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.WindowBackground
import com.nostrvault.ui.theme.ZapOrange

/**
 * Account switcher bottom sheet matching the iOS AccountSwitcherView.
 * Shows owner account and any whitelisted accounts with tap-to-switch.
 */

data class AccountInfo(
    val npub: String,
    val hexPubkey: String,
    val displayName: String,
    val isOwner: Boolean,
    val isActive: Boolean,
    val hasKey: Boolean,
    val avatarUrl: String? = null,
)

/**
 * Build the account roster with resolved names/avatars from the profile map.
 * Shared by the global switcher (NavGraph) and the in-composer switcher.
 * [includeWhitelisted] adds relay-follow accounts (whitelistedNpubs) on top of
 * the multi-account roster (owner + accountNpubs).
 */
fun buildAccountInfos(
    config: HavenConfig,
    profiles: Map<String, FeedProfile>,
    includeWhitelisted: Boolean = true,
): List<AccountInfo> {
    val active = config.activeOrOwnerNpub()
    val roster = buildList {
        addAll(config.allAccountNpubs())
        if (includeWhitelisted) config.whitelistedNpubs?.let { addAll(it) }
    }.distinct().filter { it.isNotEmpty() }
    return roster.map { npub ->
        val isOwner = npub == config.ownerNpub
        val hex = HavenBridge.decodeNpub(npub) ?: ""
        val profile = profiles[hex]
        AccountInfo(
            npub = npub,
            hexPubkey = hex,
            // iOS names an unknown account by the first 8 characters of its npub.
            displayName = profile?.bestName ?: if (isOwner) "Owner" else npub.take(8),
            isOwner = isOwner,
            isActive = npub == active,
            hasKey = isOwner || npub in config.accountNpubs,
            avatarUrl = profile?.pictureURL,
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AccountSwitcherSheet(
    accounts: List<AccountInfo>,
    onSelectAccount: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState()
    val colors = LocalNostrVaultColors.current

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = WindowBackground,
        contentColor = PrimaryText,
        shape = RoundedCornerShape(topStart = 16.dp, topEnd = 16.dp),
    ) {
        Column(modifier = Modifier.padding(bottom = 24.dp)) {
            // Header
            Text(
                text = "Switch Account",
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
                color = PrimaryText,
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 12.dp),
            )

            HorizontalDivider(color = Color.White.copy(alpha = 0.08f))

            Spacer(modifier = Modifier.height(8.dp))

            // Account rows
            for (account in accounts) {
                AccountRow(
                    account = account,
                    themeColor = colors.primary,
                    onClick = {
                        onSelectAccount(account.npub)
                        onDismiss()
                    },
                )
            }
        }
    }
}

@Composable
private fun AccountRow(
    account: AccountInfo,
    themeColor: Color,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .then(
                if (account.isActive) Modifier.background(themeColor.copy(alpha = 0.08f))
                else Modifier
            )
            .padding(horizontal = 20.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // Avatar with ring
        Box(
            modifier = Modifier.size(38.dp),
            contentAlignment = Alignment.Center,
        ) {
            Box(
                modifier = Modifier
                    .size(34.dp)
                    .clip(CircleShape)
                    .background(SecondaryGroupedBg)
                    .border(
                        width = if (account.isActive) 2.dp else 0.dp,
                        color = if (account.isActive) {
                            if (account.isOwner) themeColor else ZapOrange
                        } else Color.Transparent,
                        shape = CircleShape,
                    ),
                contentAlignment = Alignment.Center,
            ) {
                AvatarImage(
                    url = account.avatarUrl,
                    pubkey = account.hexPubkey,
                    size = 30.dp,
                    displayName = account.displayName,
                )
            }
        }

        Spacer(modifier = Modifier.width(12.dp))

        // Name + badges
        Column(modifier = Modifier.weight(1f)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Text(
                    text = account.displayName,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = PrimaryText,
                    maxLines = 1,
                )
                if (account.isOwner) {
                    Text(
                        text = "Owner",
                        fontSize = 10.sp,
                        fontWeight = FontWeight.Bold,
                        color = themeColor,
                        modifier = Modifier
                            .background(themeColor.copy(alpha = 0.15f), RoundedCornerShape(4.dp))
                            .padding(horizontal = 5.dp, vertical = 2.dp),
                    )
                }
            }
            Text(
                text = account.npub.take(20) + "...",
                fontSize = 11.sp,
                color = SecondaryText,
                maxLines = 1,
                fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
            )
        }

        // Key status
        Icon(
            imageVector = NostrVaultIcons.Accounts,
            contentDescription = null,
            tint = if (account.hasKey) SecondaryText.copy(alpha = 0.4f) else ZapOrange,
            modifier = Modifier.size(14.dp),
        )

        Spacer(modifier = Modifier.width(8.dp))

        // Active checkmark
        Icon(
            imageVector = if (account.isActive) NostrVaultIcons.Check else NostrVaultIcons.AccountCircle,
            contentDescription = null,
            tint = if (account.isActive) themeColor else SecondaryText.copy(alpha = 0.3f),
            modifier = Modifier.size(18.dp),
        )
    }
}
