package com.nostrvault.service.emoji

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.vaultAuthRelayTag
import com.nostrvault.service.EmojiListRepository
import com.nostrvault.service.ListBackupService
import com.nostrvault.service.ListVersion
import com.nostrvault.service.NostrEvent
import com.nostrvault.service.NostrService
import com.nostrvault.service.VaultSocket
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Finds the person's own old emoji sets ([OwnEmojiSets]) and adds one back. Reads: their relays
 * ([EmojiSetBrowser.ownVersions]), the vault, and the vault's list history (/lists keeps every 30030 version since
 * haven-go protects the kind). Add back signs nothing itself: a wiped set goes back through List backups' restore
 * ([ListBackupService.restore], the one safe save with its undo copy), then the 10030 gets its `a` tag through
 * [EmojiListSave]. Only on a tap.
 */
@Singleton
class OwnEmojiSetFinder @Inject constructor(
    private val nostrService: NostrService,
    private val configStore: ConfigStore,
    private val browser: EmojiSetBrowser,
    private val backups: ListBackupService,
    private val listSave: EmojiListSave,
    private val emojiList: EmojiListRepository,
) {
    data class Found(
        val owner: String,
        val sets: List<OwnEmojiSets.OldSet>,
        /** Signed copies by id: what Add back sends on for a set that only needs listing. */
        val events: Map<String, NostrEvent>,
        /** The vault answered; else only relays were read. */
        val vaultRead: Boolean,
    )

    suspend fun find(): Found {
        val owner = configStore.activeAccountHexPubkey.value
        if (owner.isEmpty()) return Found(owner, emptyList(), emptyMap(), vaultRead = false)
        val filter = "\"authors\":[\"$owner\"],\"kinds\":[${OwnEmojiSets.KIND}]"
        val (relays, vault, history) = coroutineScope {
            val relays = async { runCatching { browser.ownVersions(owner) }.getOrDefault(emptyList()) }
            val vault = async { vaultQuery("", filter) }
            val history = async { vaultQuery("lists", filter) }
            Triple(relays.await(), vault.await(), history.await())
        }
        val events = (relays + vault.orEmpty() + history.orEmpty()).filter { it.pubkey == owner }.associateBy { it.id }
        val listed = emojiList.library.value.takeIf { it.owner == owner }?.sets?.map { it.address }?.toSet().orEmpty()
        val sets = OwnEmojiSets.pick(events.values.map(ListVersion::of), owner, listed)
        return Found(owner, sets, events, vaultRead = vault != null || history != null)
    }

    /** Brings [old] back; null when done, else what to tell the person. */
    suspend fun addBack(old: OwnEmojiSets.OldSet, found: Found): String? {
        if (configStore.activeAccountHexPubkey.value != found.owner) return "This set belongs to another account. Switch to it first."
        if (old.restore) {
            val preview = backups.preview(old.version).getOrElse { return it.message ?: "Couldn't read your newest copy of this set. Nothing was changed." }
            backups.restore(old.version, preview)?.let { return it }
        }
        if (old.listed) {
            emojiList.refresh(force = true, wide = true)
            return null
        }
        // A restored set is already on the relays and in the vault; an unchanged one is sent on with its listing.
        return listSave.change(old.address, add = true, setEvent = if (old.restore) null else found.events[old.version.id])
    }

    /** Every own 30030 at the vault's [path] relay ("" main, "lists" history), or null when it couldn't be read. */
    private suspend fun vaultQuery(path: String, filter: String): List<NostrEvent>? {
        val url = configStore.config.value.localRelayURL(path) ?: return null
        return runCatching { VaultSocket.queryAll(url, filter, { signAuth(url, it) }) }.getOrNull()
    }

    private suspend fun signAuth(url: String, challenge: String): NostrEvent? = runCatching {
        nostrService.signEventAsync(
            kind = 22242,
            content = "",
            tags = listOf(listOf("relay", configStore.config.value.vaultAuthRelayTag(url)), listOf("challenge", challenge)),
            forceOwner = true,
        )
    }.getOrNull()
}
