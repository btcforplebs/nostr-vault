package com.nostrvault.data.model

/**
 * The other accounts' Vault lists, kept ready so a chip tap (All, or another
 * account) only flips the chip (Logen 2026-11-14, "switching should be
 * instant"). Each account's events are held and topped up in the background;
 * a read never drops what an earlier one brought, so the list on screen does
 * not reshuffle under the finger.
 */
object VaultOtherAccounts {
    /** Events held per account: the newest this many. */
    const val HELD_CAP = 1_000

    /**
     * The phone's own vault: its outbox and inbox. The device relay holds
     * every account's events, so a chip never waits on a remote relay.
     */
    fun localRelays(outbox: String?, inbox: String?): List<String> =
        listOfNotNull(outbox?.takeIf { it.isNotEmpty() }, inbox?.takeIf { it.isNotEmpty() }).distinct()

    /** Every account but the active one: all of them are read ahead of a tap. */
    fun wanted(accounts: List<String>, active: String): List<String> {
        val me = active.lowercase()
        return accounts.filter { it != me }
    }

    /** The `,"since":…` of a top-up from what is held; empty (read everything) when nothing is. */
    fun sinceClause(held: Collection<VaultActivity.Event>, now: Long): String =
        VaultActivity.refreshSince(held.maxOfOrNull { it.createdAt }, now)?.let { ",\"since\":$it" } ?: ""

    /** [held] with [fresh] folded in by id, the newest [cap] kept. */
    fun fold(
        held: Map<String, VaultActivity.Event>,
        fresh: List<VaultActivity.Event>,
        cap: Int = HELD_CAP,
    ): Map<String, VaultActivity.Event> {
        if (fresh.isEmpty() && held.size <= cap) return held
        val all = HashMap(held)
        for (e in fresh) all[e.id] = e
        if (all.size <= cap) return all
        return all.values.sortedByDescending { it.createdAt }.take(cap).associateBy { it.id }
    }
}
