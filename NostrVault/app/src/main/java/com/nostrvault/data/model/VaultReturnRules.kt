package com.nostrvault.data.model

/**
 * The Vault tab on return and on an account switch (Logen 2026-11-13: "the
 * Vault tab button is red and the tab has a hard time loading; I see new
 * followers first, then everything else gets injected after"). Android twin
 * of iOS VaultReturnRules (#2034).
 *
 * Pure rules, so unit tests can hold them; VaultActivityViewModel wires the
 * list swap and the saved screen, DashboardViewModel the Notes snapshot, and
 * RelayForegroundService the per-account dot.
 */
object VaultListSwap {
    /**
     * The longest a refresh keeps the old list up before the new one shows
     * anyway, so a relay that never answers can't freeze the screen.
     */
    const val CAP_MS = 3_000L

    /**
     * Whether a freshly built Vault list goes on screen now. While a refresh
     * is reading, the list on screen stays and the new one waits until the
     * read is done (or [CAP_MS] passed), so rows don't pop in one batch at a
     * time and followers (read from the ledger, first) never show alone.
     * [force]: the build is the saved screen for an account just opened,
     * which shows at once. [heldForMs]: how long a build has been held (null:
     * none yet).
     */
    fun publishes(force: Boolean, refreshing: Boolean, heldForMs: Long?): Boolean {
        if (force || !refreshing) return true
        return heldForMs != null && heldForMs >= CAP_MS
    }
}

/** What a saved Vault screen keeps, and where. */
object VaultSnapshotRules {
    /** The newest events kept: enough for the first page of every Vault list. */
    const val KEEP = 400

    /** The newest [keep] of [items], newest first. */
    fun <T> newest(items: Collection<T>, keep: Int = KEEP, createdAt: (T) -> Long): List<T> =
        items.sortedByDescending(createdAt).take(keep)

    /**
     * The file for an account's saved screen of [list]: its hex pubkey and
     * nothing else, so a malformed key can't reach outside the folder.
     */
    fun fileName(list: String, account: String): String? {
        val hex = account.lowercase()
        if (hex.length != 64 || !hex.all { it in '0'..'9' || it in 'a'..'f' }) return null
        return "$list-$hex.json"
    }
}

/**
 * The Vault tab's dot, one per account: each account keeps its own lists
 * with news, and a list lights only for something dated after that
 * account's last visit to it.
 */
class VaultNewsAccounts<M> {
    private val modes = HashMap<String, Set<M>>()

    /**
     * Stash what [from] shows now ([current]) and hand back what [to] showed
     * when you last left it (nothing new for one never opened here).
     */
    @Synchronized
    fun switchAccount(from: String, to: String, current: Set<M>): Set<M> {
        val f = from.lowercase()
        val t = to.lowercase()
        if (f.isNotEmpty()) modes[f] = current
        if (f == t) return current
        return modes[t] ?: emptySet()
    }

    companion object {
        /**
         * Whether events from others dated [createdAt] (unix seconds) are news
         * to an account whose list was last seen at [lastVisit] (null: never).
         * A catch-up storing an old like you already saw elsewhere is not.
         */
        fun isNews(createdAt: Collection<Long>, lastVisit: Long?): Boolean {
            if (lastVisit == null) return createdAt.isNotEmpty()
            return createdAt.any { it > lastVisit }
        }
    }
}
