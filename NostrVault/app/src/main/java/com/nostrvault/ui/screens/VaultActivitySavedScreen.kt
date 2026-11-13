package com.nostrvault.ui.screens

import com.nostrvault.data.model.VaultActivity
import com.nostrvault.data.model.VaultMode
import com.nostrvault.data.model.VaultNewsAccounts
import kotlinx.serialization.Serializable

/**
 * The "Vault" list's saved screen and news check (Logen 2026-11-13; iOS
 * #2034): what VaultActivityViewModel keeps on disk per account, and whether
 * a list the relay proposed for the dot has real news.
 */
internal object VaultActivitySavedScreen {
    /** One held event as saved; its pictures are worked out again on read. */
    @Serializable
    data class Saved(
        val id: String,
        val pubkey: String,
        val kind: Int,
        val createdAt: Long,
        val content: String,
        val tags: List<List<String>>,
    )

    fun save(event: VaultActivity.Event) =
        Saved(event.id, event.pubkey, event.kind, event.createdAt, event.content, event.tags)

    fun load(saved: Saved) = VaultActivity.Event(
        saved.id, saved.pubkey, saved.kind, saved.createdAt, saved.content, saved.tags,
        VaultActivity.pictures(saved.id, saved.pubkey, saved.kind, saved.createdAt, saved.content, saved.tags),
    )

    /** The lists a visit to [mode] sees: "Vault" shows everything. */
    fun visited(mode: VaultMode): List<VaultMode> =
        if (mode == VaultMode.ACTIVITY) NEWS_LISTS else listOf(mode)

    private val NEWS_LISTS = listOf(VaultMode.NOTES, VaultMode.LIKES, VaultMode.ZAPS, VaultMode.ARTICLES, VaultMode.HIGHLIGHTS)

    /**
     * Whether [events] hold news for [account]'s [mode] list: an event from
     * someone not among [ownAccounts], tagging [account], dated after
     * [lastVisit]. A catch-up of something already seen is not.
     */
    fun hasNews(
        events: Collection<VaultActivity.Event>,
        mode: VaultMode,
        account: String,
        ownAccounts: Set<String>,
        lastVisit: Long?,
    ): Boolean {
        val owner = account.lowercase()
        val dates = events.filter { e ->
            VaultMode.listing(e.kind) == mode &&
                e.pubkey.lowercase() !in ownAccounts && e.pubkey.lowercase() != owner &&
                e.tags.any { it.size >= 2 && it[0] == "p" && it[1].lowercase() == owner }
        }.map { it.createdAt }
        return VaultNewsAccounts.isNews(dates, lastVisit)
    }
}
