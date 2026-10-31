package com.nostrvault.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.AccountUnread
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.VaultAccountChip
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.PrimaryText

/**
 * "All · <acct> · <acct>": the active account first after All, each other
 * account with its new-notification count from the switcher. iOS:
 * VaultAccountScope.swift's accountChipRow.
 */
@Composable
internal fun AccountChipRow(
    chips: List<VaultAccountChip>,
    selected: VaultAccountChip,
    activeHex: String,
    profiles: Map<String, FeedProfile>,
    counts: AccountUnread,
    onPick: (VaultAccountChip) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalNostrVaultColors.current
    Row(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 16.dp),
    ) {
        chips.forEach { chip ->
            val isSelected = chip == selected
            val hex = (chip as? VaultAccountChip.Account)?.hex
            val title = hex?.let { profiles[it]?.bestName ?: ("npub…" + it.takeLast(6)) } ?: "All"
            // The active account's count lives on the Vault tab's own dot.
            val badge = hex?.takeIf { it != activeHex }?.let { AccountUnread.badge(counts.count(it)) }
            Surface(
                onClick = { onPick(chip) },
                shape = CircleShape,
                color = if (isSelected) colors.primary else colors.primary.copy(alpha = 0.10f),
                modifier = Modifier
                    .heightIn(min = 36.dp)
                    .semantics {
                        contentDescription = badge?.let { "$title, $it new" } ?: title
                        if (isSelected) stateDescription = "Selected"
                    },
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.padding(start = if (hex == null) 14.dp else 5.dp, end = 12.dp, top = 6.dp, bottom = 6.dp),
                ) {
                    if (hex != null) {
                        AvatarImage(url = profiles[hex]?.pictureURL, pubkey = hex, size = 22.dp, displayName = profiles[hex]?.bestName)
                        Spacer(Modifier.width(6.dp))
                    }
                    Text(
                        title,
                        color = if (isSelected) Color.White else PrimaryText,
                        fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
                        maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                    if (badge != null) {
                        Spacer(Modifier.width(6.dp))
                        Box(
                            contentAlignment = Alignment.Center,
                            modifier = Modifier
                                .heightIn(min = 18.dp)
                                .background(if (isSelected) Color.White else colors.primary, CircleShape)
                                .padding(horizontal = 5.dp),
                        ) {
                            Text(
                                badge,
                                color = if (isSelected) colors.primary else Color.White,
                                fontSize = 10.sp, fontWeight = FontWeight.Bold,
                            )
                        }
                    }
                }
            }
        }
    }
}
