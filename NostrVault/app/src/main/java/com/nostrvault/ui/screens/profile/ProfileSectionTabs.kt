package com.nostrvault.ui.screens.profile

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.*

// iOS ProfileView.sectionTabBar: uppercase heavy labels + mono counts over a
// 2dp underline on the selected section.
@Composable
internal fun ProfileSectionTabs(
    selected: ProfileSection,
    counts: ProfileCounts,
    /** Whether older pages may still raise a tab's count; it reads "48+" until they can't. */
    hasMore: (ProfileSection) -> Boolean,
    /** Counts for the tabs that are not notes: Shop, Articles, diVines, Music. */
    extraCounts: Map<ProfileSection, Int>,
    shown: (ProfileSection) -> Boolean,
    onSelect: (ProfileSection) -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    fun countFor(s: ProfileSection): Int = when (s) {
        ProfileSection.NOTES -> counts.notes
        ProfileSection.MEDIA -> counts.media
        ProfileSection.REPLIES -> counts.replies
        ProfileSection.REPOSTS -> counts.reposts
        ProfileSection.TAGGED -> counts.tagged
        else -> extraCounts[s] ?: 0
    }
    val slots = ProfileTabSlots.of(ProfileSection.entries.filter(shown))
    val moreSelected = ProfileTabSlots.moreSelection(slots, selected)
    var moreOpen by remember { mutableStateOf(false) }
    fun labelFor(s: ProfileSection): String? = countFor(s).let { c -> if (c > 0) ProfileCountText.of(c, hasMore(s)) else null }
    Row(modifier = Modifier
        .fillMaxWidth()
        .padding(horizontal = 16.dp)) {
        slots.tabs.forEach { section ->
            ProfileTabCell(
                icon = section.icon,
                label = labelFor(section),
                isSelected = section == selected,
                description = section.displayName,
                onClick = { onSelect(section) },
                modifier = Modifier.weight(1f),
            )
        }
        if (slots.more.isNotEmpty()) {
            Box(modifier = Modifier.weight(1f)) {
                ProfileTabCell(
                    // The open kind's icon once one is picked from the list.
                    icon = moreSelected?.icon ?: Icons.Filled.MoreHoriz,
                    label = moreSelected?.let { labelFor(it) },
                    isSelected = moreSelected != null,
                    description = moreSelected?.let { "${it.displayName}, more kinds" } ?: "More kinds",
                    onClick = { moreOpen = true },
                    trailing = moreSelected != null,
                    modifier = Modifier.fillMaxWidth(),
                )
                DropdownMenu(expanded = moreOpen, onDismissRequest = { moreOpen = false }) {
                    slots.more.forEach { section ->
                        val label = labelFor(section)
                        DropdownMenuItem(
                            text = {
                                Text(
                                    section.displayName,
                                    fontWeight = if (section == selected) FontWeight.SemiBold else FontWeight.Normal,
                                    color = if (section == selected) colors.primary else Color.Unspecified,
                                )
                            },
                            leadingIcon = {
                                Icon(
                                    section.icon,
                                    contentDescription = null,
                                    tint = if (section == selected) colors.primary else SecondaryText,
                                    modifier = Modifier.size(18.dp),
                                )
                            },
                            trailingIcon = label?.let {
                                {
                                    Text(it, fontSize = 11.sp, fontFamily = FontFamily.Monospace, color = SecondaryText)
                                }
                            },
                            onClick = {
                                moreOpen = false
                                onSelect(section)
                            },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun ProfileTabCell(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String?,
    isSelected: Boolean,
    description: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    /** A small chevron after the icon: this tab opens a list. */
    trailing: Boolean = false,
) {
    val colors = LocalNostrVaultColors.current
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = modifier
            .clickable(onClickLabel = description) { onClick() }
            .semantics { contentDescription = description + (label?.let { ", $it" } ?: "") }
            .padding(top = 4.dp),
    ) {
        // Icons, as the feed types show them: icon and count, or the
        // icon alone on a tab too narrow for the count (iOS #280).
        BoxWithConstraints(contentAlignment = Alignment.Center, modifier = Modifier.fillMaxWidth().height(20.dp)) {
            val fitsCount = label != null && maxWidth >= ProfileTabFiller.tabWidthWithCount(label.length)
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Icon(
                    icon,
                    contentDescription = null,
                    tint = if (isSelected) colors.primary else SecondaryText,
                    modifier = Modifier.size(14.dp),
                )
                if (fitsCount && label != null) {
                    Text(
                        text = label,
                        fontSize = 10.sp,
                        fontWeight = FontWeight.SemiBold,
                        fontFamily = FontFamily.Monospace,
                        maxLines = 1,
                        softWrap = false,
                        color = SecondaryText,
                    )
                }
                if (trailing) {
                    Icon(
                        NostrVaultIcons.ChevronDown,
                        contentDescription = null,
                        tint = SecondaryText,
                        modifier = Modifier.size(12.dp),
                    )
                }
            }
        }
        Spacer(Modifier.height(6.dp))
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(2.dp)
                .background(if (isSelected) colors.primary else Color.Transparent),
        )
    }
}

/** The feed types' own icons, so a tab reads the same as the feed it matches. */
internal val ProfileSection.icon: androidx.compose.ui.graphics.vector.ImageVector
    get() = when (this) {
        ProfileSection.NOTES -> NostrVaultIcons.Chat
        ProfileSection.MEDIA -> NostrVaultIcons.Media
        ProfileSection.REPLIES -> NostrVaultIcons.Reply
        ProfileSection.REPOSTS -> NostrVaultIcons.Repost
        ProfileSection.ARTICLES -> NostrVaultIcons.Articles
        ProfileSection.DIVINES -> NostrVaultIcons.Reels
        ProfileSection.MUSIC -> NostrVaultIcons.Music
        ProfileSection.TAGGED -> NostrVaultIcons.At
        ProfileSection.SHOP -> NostrVaultIcons.Marketplace
    }
