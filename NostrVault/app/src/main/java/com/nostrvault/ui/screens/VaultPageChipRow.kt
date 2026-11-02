package com.nostrvault.ui.screens

import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.nostrvault.data.model.VaultAccountChips
import com.nostrvault.ui.screens.dashboard.DashboardViewModel
import com.nostrvault.ui.screens.dashboard.pickPageChip

/**
 * The account chips over Notes, Articles, Highlights, Likes, Zaps and
 * Followers (not Media; the Vault list has its own): the Vault list's chips,
 * "All" and each account. A chip only filters what the page shows; the
 * account switches when a note is opened (Logen 11-02).
 * iOS: VaultPageChipRow.
 */
@Composable
internal fun VaultPageChipRow(activity: VaultActivityViewModel, pages: DashboardViewModel) {
    val accountHexes by activity.accountHexes.collectAsState()
    val activeHex by activity.activeHex.collectAsState()
    val profiles by activity.profiles.collectAsState()
    val unreadCounts by activity.accountUnreadState.collectAsState()
    val picked by pages.pageChip.collectAsState()
    val chips = remember(accountHexes, activeHex) { VaultAccountChips.chips(accountHexes, activeHex) }
    if (chips.isEmpty()) return
    AccountChipRow(
        chips = chips,
        selected = VaultAccountChips.resolve(picked, accountHexes, activeHex),
        activeHex = activeHex,
        profiles = profiles,
        counts = unreadCounts,
        onPick = pages::pickPageChip,
        modifier = Modifier.padding(bottom = 8.dp),
    )
}
