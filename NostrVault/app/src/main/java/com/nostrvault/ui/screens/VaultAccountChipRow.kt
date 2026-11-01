package com.nostrvault.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.clickable
import com.nostrvault.data.model.AccountUnread
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.VaultAccountChip
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.PrimaryText

/** The size of each account's picture in the row. */
internal val AccountChipPictureSize = 40.dp

/**
 * "All", then each account's picture: the active account first after All.
 * No names (each picture says its name aloud); a ring marks the picked one,
 * and a red bubble another account's new-notification count from the
 * switcher. iOS: VaultAccountScope.swift's accountChipRow.
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
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            // Room for the ring and the red bubble's overhang.
            .padding(horizontal = 16.dp, vertical = 6.dp),
    ) {
        chips.forEach { chip ->
            val isSelected = chip == selected
            val hex = (chip as? VaultAccountChip.Account)?.hex
            val title = hex?.let { profiles[it]?.bestName ?: ("npub…" + it.takeLast(6)) } ?: "All"
            // The active account's count lives on the Vault tab's own dot.
            val badge = hex?.takeIf { it != activeHex }?.let { AccountUnread.badge(counts.count(it)) }
            val described = Modifier.semantics {
                contentDescription = badge?.let { "$title, $it new" } ?: title
                role = Role.Button
                if (isSelected) stateDescription = "Selected"
            }
            if (hex == null) {
                Surface(
                    onClick = { onPick(chip) },
                    shape = CircleShape,
                    color = if (isSelected) colors.primary else colors.primary.copy(alpha = 0.10f),
                    modifier = described.heightIn(min = AccountChipPictureSize + 6.dp),
                ) {
                    Box(contentAlignment = Alignment.Center, modifier = Modifier.padding(horizontal = 16.dp).heightIn(min = AccountChipPictureSize + 6.dp)) {
                        Text(
                            title,
                            color = if (isSelected) Color.White else PrimaryText,
                            fontSize = 15.sp, fontWeight = FontWeight.SemiBold,
                            maxLines = 1,
                        )
                    }
                }
            } else {
                Box(modifier = described) {
                    Box(
                        contentAlignment = Alignment.Center,
                        modifier = Modifier
                            .size(AccountChipPictureSize + 6.dp)
                            .clip(CircleShape)
                            .border(2.5.dp, if (isSelected) colors.primary else Color.Transparent, CircleShape)
                            .clickable { onPick(chip) },
                    ) {
                        AvatarImage(
                            url = profiles[hex]?.pictureURL, pubkey = hex,
                            size = AccountChipPictureSize, displayName = profiles[hex]?.bestName,
                        )
                    }
                    if (badge != null) {
                        Box(
                            contentAlignment = Alignment.Center,
                            modifier = Modifier
                                .align(Alignment.TopEnd)
                                .offset(x = 6.dp, y = (-4).dp)
                                .heightIn(min = 20.dp)
                                .widthIn(min = 20.dp)
                                .background(Color(0xFFFF3B30), CircleShape)
                                .padding(horizontal = 5.dp),
                        ) {
                            Text(badge, color = Color.White, fontSize = 11.sp, fontWeight = FontWeight.Bold)
                        }
                    }
                }
            }
        }
    }
}
