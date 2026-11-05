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
 * A Vault line and the accounts it is for. One event that tags several of your accounts (a reply, mention, quote,
 * article, highlight or a zap with words) is one line for all of them ([VaultAccountChips.isOneEvent]); a folded line
 * (a post's likes, reposts, a day's follows) stays per account, since each account's is a different set of events.
 * The key carries the first account, so per-account folds with the same id stay apart. iOS: VaultAccountLine (#1772).
 */
data class VaultAccountLine(val accounts: List<String>, val line: VaultActivity) {
    constructor(account: String, line: VaultActivity) : this(listOf(account), line)

    /** The first account (switcher order): the line's own when it is for one. */
    val account: String get() = accounts.firstOrNull().orEmpty()
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
     * Whether a page shows the chips over it (Notes, Articles, Highlights,
     * Likes, Zaps, Followers): the same chips as the Vault list, which has
     * its own row; Media has none. On the pages a chip only filters
     * (VaultPageAccounts). iOS: pageShowsChipRow.
     */
    fun pageShowsChipRow(mode: VaultMode): Boolean = when (mode) {
        VaultMode.NOTES, VaultMode.ARTICLES, VaultMode.HIGHLIGHTS,
        VaultMode.LIKES, VaultMode.ZAPS, VaultMode.FOLLOWERS -> true
        VaultMode.ACTIVITY, VaultMode.MEDIA, VaultMode.BOOKMARKS -> false
    }

    /**
     * Whether picking [chip] must wait for a read: it shows another account
     * whose lines aren't read yet. Until then the list on screen stays and only
     * the ring moves, so a pick never flashes a spinner or an empty list.
     * iOS: needsRead.
     */
    fun needsRead(chip: VaultAccountChip, accounts: List<String>, active: String, loaded: Set<String>): Boolean {
        val me = active.lowercase()
        return accounts(chip, accounts).any { it != me && it !in loaded }
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
     * Whether the line is one event, the same event for every account it tagged: a reply, mention, quote, article,
     * highlight, or a zap with its own line. Folded lines ("reaction-", "repost-", "zap-", "follow-") gather
     * different events per account. iOS: isOneEvent (#1772).
     */
    fun isOneEvent(line: VaultActivity): Boolean = when (line.kind) {
        VaultActivity.Kind.REPLY, VaultActivity.Kind.MENTION, VaultActivity.Kind.QUOTE,
        VaultActivity.Kind.ARTICLE, VaultActivity.Kind.HIGHLIGHT -> true
        VaultActivity.Kind.ZAP -> !line.id.startsWith("zap-")
        VaultActivity.Kind.REACTION, VaultActivity.Kind.REPOST, VaultActivity.Kind.FOLLOW -> false
    }

    /**
     * Each account's lines in one list, newest first, each marked with its accounts: one event that tagged several
     * of them is one line ([isOneEvent]). A shared line's accounts are in switcher order. Ties go to the account
     * first in [order], then by id, so the list never shuffles between rebuilds.
     */
    fun merge(perAccount: Map<String, List<VaultActivity>>, order: List<String>, limit: Int): List<VaultAccountLine> {
        val rank = unique(order).withIndex().associate { (i, hex) -> hex to i }
        val accounts = perAccount.keys.map { it.lowercase() }.distinct()
            .sortedWith(compareBy<String> { rank[it] ?: Int.MAX_VALUE }.thenBy { it })
        val lines = HashMap<String, MutableList<VaultActivity>>()
        for ((account, list) in perAccount) lines.getOrPut(account.lowercase()) { mutableListOf() } += list
        val all = mutableListOf<VaultAccountLine>()
        val shared = HashMap<String, Int>()
        for (account in accounts) {
            for (line in lines[account].orEmpty()) {
                if (!isOneEvent(line)) {
                    all += VaultAccountLine(account, line)
                    continue
                }
                val at = shared[line.id]
                if (at == null) {
                    shared[line.id] = all.size
                    all += VaultAccountLine(account, line)
                } else if (account !in all[at].accounts) {
                    all[at] = all[at].copy(accounts = all[at].accounts + account)
                }
            }
        }
        return all
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
