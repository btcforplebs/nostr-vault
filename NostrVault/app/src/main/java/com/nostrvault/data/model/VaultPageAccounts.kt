package com.nostrvault.data.model

/**
 * The account chips over the Vault's other pages (Notes, Articles,
 * Highlights, Likes, Zaps, Followers; not Media). They are the Vault list's
 * chips: "All" and each account. Every account's data is loaded, and a chip
 * only filters what the page shows; nothing switches until a note is opened
 * (Logen 11-02). iOS: VaultPageAccounts.
 */
object VaultPageAccounts {

    /**
     * The accounts the page shows for the picked chip, the active one first.
     * Null (nothing picked) or a chip that is gone is the active account's
     * own page, exactly as with one account.
     */
    fun owners(picked: VaultAccountChip?, accounts: List<String>, active: String): List<String> {
        val me = active.lowercase()
        val chip = VaultAccountChips.resolve(picked, accounts, me)
        val shown = VaultAccountChips.accounts(chip, accounts)
        return if (me in shown) listOf(me) + shown.filter { it != me } else shown
    }

    /**
     * Who a row is for: its author when that is one of [owners], else the
     * first of [owners] it tags (in [owners] order). Null when it is neither,
     * such as a whitelisted author's note.
     */
    fun rowAccount(author: String, tags: List<List<String>>, owners: List<String>): String? {
        val by = author.lowercase()
        if (by in owners) return by
        val tagged = tags.asSequence().filter { it.size >= 2 && it[0] == "p" }.map { it[1].lowercase() }.toSet()
        return owners.firstOrNull { it in tagged }
    }

    /**
     * Every account on the device, plus the whitelisted, for the relay's
     * subscriptions: the page loads them all so a chip never has to wait.
     */
    fun authors(accounts: List<String>, active: String, whitelist: Collection<String>): Set<String> =
        (listOf(active.lowercase()) + accounts.map { it.lowercase() } + whitelist)
            .filter { it.isNotEmpty() }
            .toCollection(LinkedHashSet())

    /** The accounts a `#p` filter asks for: the active one first, then the others. */
    fun tagged(accounts: List<String>, active: String): List<String> =
        (listOf(active.lowercase()) + accounts.map { it.lowercase() }).filter { it.isNotEmpty() }.distinct()

    /**
     * Whether an event belongs to the active account's own lists, as when
     * only its data was loaded: its own, a whitelisted author's, or one that
     * tags it. The list dots count only these, so another account's activity
     * never lights them.
     */
    fun isActiveAccounts(author: String, tags: List<List<String>>, active: String, whitelist: Set<String>): Boolean {
        val me = active.lowercase()
        if (author == me || author in whitelist) return true
        return tags.any { it.size >= 2 && it[0] == "p" && it[1].lowercase() == me }
    }

    /** Whether [author] is an account on this device: its notes are yours, so no Report or Block. */
    fun isOwnAccount(author: String, accounts: List<String>, active: String): Boolean {
        val by = author.lowercase()
        return by == active.lowercase() || by in accounts.map { it.lowercase() }
    }

    /**
     * Whether a row gets the long-press Report / Block menu. Not on a row
     * listed for another account ([rowAccount] non-null): those would act as
     * the active account on a list it isn't looking at as itself. Not on a
     * note by any account on this device. iOS: NoteRow isOtherAccountRow (#1562).
     */
    fun showsRowMenu(author: String, rowAccount: String?, accounts: List<String>, active: String): Boolean =
        rowAccount == null && !isOwnAccount(author, accounts, active)

    /**
     * Several accounts' followers as one list: each follower once (a current
     * follow over an ended one, then the newest), follows we watched first as the ledger orders
     * them. Counts add up per account, so someone following two of them
     * counts twice, as each account's own count does.
     */
    fun mergeFollowers(snapshots: List<FollowerSnapshot>): FollowerSnapshot? {
        if (snapshots.isEmpty()) return null
        if (snapshots.size == 1) return snapshots.single()
        val byPubkey = LinkedHashMap<String, FollowerSnapshot.Entry>()
        val newestFirst = snapshots.flatMap { it.followers.orEmpty() }.sortedWith(
            compareByDescending<FollowerSnapshot.Entry> { it.following }.thenByDescending { maxOf(it.followedAt, it.listAt) },
        )
        for (entry in newestFirst) {
            byPubkey.putIfAbsent(entry.pubkey, entry)
        }
        val counts = snapshots.map { it.counts }.reduce { a, b ->
            FollowerSnapshot.Counts(
                trusted = a.trusted + b.trusted,
                others = a.others + b.others,
                spam = a.spam + b.spam,
                unfollowed = a.unfollowed + b.unfollowed,
            )
        }
        return FollowerSnapshot(counts = counts, followers = byPubkey.values.toList())
    }
}
