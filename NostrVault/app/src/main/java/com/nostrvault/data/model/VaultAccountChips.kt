package com.nostrvault.data.model

/**
 * One chip over the Vault list when the device holds more than one account:
 * every account's notifications together, or one account's.
 * iOS: VaultAccountChips.swift.
 */
sealed class VaultAccountChip {
    data object All : VaultAccountChip()

    /** One account, by hex pubkey (lowercase). */
    data class Account(val hex: String) : VaultAccountChip()
}

/**
 * A Vault line and the account it is for. Two accounts can each have a line
 * with the same id (a day's follows, a like on a post both were tagged in),
 * so the key carries the account.
 */
data class VaultAccountLine(val account: String, val line: VaultActivity) {
    val key: String get() = "$account:${line.id}"
}

/**
 * The rules behind the chips: which ones show, which accounts a chip's list
 * holds, and how their lines interleave. Nothing changes for one account:
 * no chips, and the list stays the active account's.
 */
object VaultAccountChips {

    /** "All", the active account, then the others in switcher order. Empty with one account. */
    fun chips(accounts: List<String>, active: String): List<VaultAccountChip> {
        val list = unique(accounts)
        if (list.size < 2) return emptyList()
        val me = active.lowercase()
        val ordered = if (me in list) listOf(me) + list.filter { it != me } else list
        return listOf(VaultAccountChip.All) + ordered.map { VaultAccountChip.Account(it) }
    }

    /**
     * The picked chip, or the active account's when none is picked or the
     * picked account is gone (removed, or the device is down to one).
     */
    fun resolve(picked: VaultAccountChip?, accounts: List<String>, active: String): VaultAccountChip {
        val me = VaultAccountChip.Account(active.lowercase())
        if (picked == null || picked !in chips(accounts, active)) return me
        return picked
    }

    /** The accounts whose lines the chip's list shows. */
    fun accounts(chip: VaultAccountChip, accounts: List<String>): List<String> = when (chip) {
        VaultAccountChip.All -> unique(accounts)
        is VaultAccountChip.Account -> listOf(chip.hex.lowercase())
    }

    /** The active account's own list, exactly as with one account. */
    fun isDefault(chip: VaultAccountChip, active: String): Boolean =
        chip == VaultAccountChip.Account(active.lowercase())

    /**
     * Each account's lines in one list, newest first, each marked with its
     * account. Ties go to the account first in [order], then by id, so the
     * list never shuffles between rebuilds.
     */
    fun merge(perAccount: Map<String, List<VaultActivity>>, order: List<String>, limit: Int): List<VaultAccountLine> {
        val rank = unique(order).withIndex().associate { (i, hex) -> hex to i }
        return perAccount.flatMap { (account, lines) -> lines.map { VaultAccountLine(account.lowercase(), it) } }
            .sortedWith(
                compareByDescending<VaultAccountLine> { it.line.createdAt }
                    .thenBy { rank[it.account] ?: Int.MAX_VALUE }
                    .thenBy { it.line.id },
            )
            .take(maxOf(0, limit))
    }

    /**
     * The npub to switch to before opening a line that is for another
     * account, so a reply or like signs as that account (the same switch a
     * tapped notification makes). Null for the active account's own lines or
     * an account the device no longer holds.
     */
    fun switchTarget(lineAccount: String?, active: String, npubByHex: Map<String, String>): String? {
        val hex = lineAccount?.lowercase()?.takeIf { it.isNotEmpty() } ?: return null
        if (hex == active.lowercase()) return null
        return npubByHex[hex]
    }

    private fun unique(list: List<String>): List<String> =
        list.map { it.lowercase() }.filter { it.isNotEmpty() }.distinct()
}
