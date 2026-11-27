package com.nostrvault.ui.screens

import com.nostrvault.data.model.VaultActivity
import com.nostrvault.data.model.VaultMode
import com.nostrvault.data.model.VaultNewsAccounts

/**
 * Whether a list the relay proposed for the Vault dot has real news (Logen
 * 2026-11-13; iOS #2034), and which lists a visit sees.
 */
internal object VaultActivityNews {
    /** The lists a visit to [mode] sees: "Vault" shows everything. */
    fun visited(mode: VaultMode): List<VaultMode> =
        if (mode == VaultMode.ACTIVITY) NEWS_LISTS else listOf(mode)

    private val NEWS_LISTS = listOf(VaultMode.NOTES, VaultMode.LIKES, VaultMode.ZAPS, VaultMode.ARTICLES, VaultMode.HIGHLIGHTS)

    /**
     * Whether [events] hold news for [account]'s [mode] list: an event from
     * someone not among [ownAccounts], tagging [account], dated after
     * [lastVisit]. A catch-up of something already seen is not.
     *
     * [hides] is the list's own rule for an author (blocked, or outside your
     * web): what the list leaves out is no news either. Spam replies from
     * outside your web lit the dot within seconds of each post while the list
     * never showed them (Tao 904cff18, 2026-11-27). Zap receipts are signed by
     * the LNURL server, not the sender, and the list never folds them.
     */
    fun hasNews(
        events: Collection<VaultActivity.Event>,
        mode: VaultMode,
        account: String,
        ownAccounts: Set<String>,
        lastVisit: Long?,
        hides: (author: String) -> Boolean = { false },
    ): Boolean {
        val owner = account.lowercase()
        val dates = events.filter { e ->
            VaultMode.listing(e.kind) == mode &&
                e.pubkey.lowercase() !in ownAccounts && e.pubkey.lowercase() != owner &&
                e.tags.any { it.size >= 2 && it[0] == "p" && it[1].lowercase() == owner } &&
                (e.kind == VaultActivity.ZAP_KIND || !hides(e.pubkey))
        }.map { it.createdAt }
        return VaultNewsAccounts.isNews(dates, lastVisit)
    }
}
