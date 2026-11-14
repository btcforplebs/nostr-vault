package com.nostrvault.ui.screens.dashboard

import androidx.lifecycle.viewModelScope
import com.nostrvault.data.model.FollowerSnapshot
import com.nostrvault.data.model.VaultAccountChip
import com.nostrvault.data.model.VaultAccountChips
import com.nostrvault.data.model.VaultPageAccounts
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// The account chips over Notes, Articles, Highlights, Likes, Zaps and
// Followers (Logen 11-02): every account's data is loaded, a chip only
// filters, and a tapped note opens as its own account. iOS: VaultPageAccounts.

/** Every account on the device for the `#p` filters, the active one first. */
internal fun DashboardViewModel.vaultTaggedAccounts(): List<String> =
    VaultPageAccounts.tagged(accountHexes.value, nostrService.activeHexPubkey)

/** The accounts the pages show for the picked chip, the active one first. */
internal fun DashboardViewModel.pageOwners(): List<String> =
    VaultPageAccounts.owners(_pageChip.value, accountHexes.value, nostrService.activeHexPubkey)

/** A chip was picked: the pages filter to it. Nothing switches and nothing reloads. */
fun DashboardViewModel.pickPageChip(chip: VaultAccountChip) {
    val active = nostrService.activeHexPubkey
    val next = if (VaultAccountChips.isDefault(chip, active)) null else chip
    if (next == _pageChip.value) return
    _pageChip.value = next
    showFollowers()
    updateJob?.cancel()
    updateGeneration++
    val gen = updateGeneration
    viewModelScope.launch { updateDisplayData(gen) }
}

/** The account a shown note is for; null when it is the active account's own. */
fun DashboardViewModel.accountForNote(noteId: String): String? =
    noteAccounts[noteId]?.takeIf { it != nostrService.activeHexPubkey.lowercase() }

/** Whether [author] is any account on this device (VaultPageAccounts.isOwnAccount). */
fun DashboardViewModel.isOwnAccount(author: String): Boolean =
    VaultPageAccounts.isOwnAccount(author, accountHexes.value, nostrService.activeHexPubkey)

/** Whether a page row gets Report / Block (VaultPageAccounts.showsRowMenu). */
fun DashboardViewModel.showsRowMenu(noteId: String, author: String): Boolean =
    VaultPageAccounts.showsRowMenu(author, accountForNote(noteId), accountHexes.value, nostrService.activeHexPubkey)

/** [hex]'s block list, as hex. The active account's comes from the feed's memo. */
internal fun DashboardViewModel.blockedHexFor(hex: String): Set<String> {
    val active = nostrService.activeHexPubkey.lowercase()
    if (hex == active) return feedService.blockedHexForActiveAccount()
    val config = configStore.config.value
    val npub = config.allAccountNpubs().firstOrNull { nostrService.npubToHex(it)?.lowercase() == hex }
        ?: return emptySet()
    return config.blockedFor(npub).mapNotNull { nostrService.npubToHex(it) }.toSet()
}

/** The other accounts' follower ledgers, each without its own blocks and judged by its own web. */
internal suspend fun DashboardViewModel.refreshOtherFollowers(active: String) {
    val others = accountHexes.value.filter { it != active.lowercase() }
    val read = withContext(Dispatchers.IO) {
        others.mapNotNull { hex ->
            runCatching { FollowerSnapshot.parse(com.nostrvault.relay.HavenBridge.getFollowers(hex)) }
                .getOrNull()?.without(blockedHexFor(hex))?.let { hex to feedService.followersJudged(it, hex) }
        }
    }
    if (active != nostrService.activeHexPubkey) return
    followerSnapshots.keys.retainAll((others + active.lowercase()).toSet())
    read.forEach { (hex, snapshot) -> followerSnapshots[hex] = snapshot }
}

/** The Followers page for the picked chip: one account's ledger, or several merged. */
internal fun DashboardViewModel.showFollowers() {
    val shown = pageOwners().mapNotNull { followerSnapshots[it] }
    _followerSnapshot.value = VaultPageAccounts.mergeFollowers(shown)
    fetchFollowerProfiles()
}

/**
 * An account added or removed: drop a chip that is gone, and read the new
 * set in full (a since-bounded re-send would miss a new account's history).
 */
internal fun DashboardViewModel.observeAccountChips() {
    viewModelScope.launch {
        // Skips the first real list (the startup load already asks for it).
        accountHexes.filter { it.isNotEmpty() }.distinctUntilChanged().drop(1).collect { accounts ->
            val active = nostrService.activeHexPubkey
            if (_pageChip.value != null && VaultAccountChips.resolve(_pageChip.value, accounts, active) != _pageChip.value) {
                _pageChip.value = null
            }
            // Not connected yet: the coming connection asks for the new set itself.
            isFullReload = true
            resendVaultSubscriptions()
            refreshFollowers()
            scheduleUpdateDisplayData()
        }
    }
}
