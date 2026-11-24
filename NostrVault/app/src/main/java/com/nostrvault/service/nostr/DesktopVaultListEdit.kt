package com.nostrvault.service

import android.util.Log
import com.nostrvault.relay.DesktopVault
import com.nostrvault.relay.DesktopVaultList
import com.nostrvault.relay.DesktopVaultListChange
import com.nostrvault.relay.DesktopVaultPath
import com.nostrvault.relay.DesktopVaultsLists
import com.nostrvault.relay.RelayDraft
import com.nostrvault.relay.desktopVaultsInEffect
import com.nostrvault.service.NostrService.Companion.isLoopbackRelay
import kotlinx.coroutines.CancellationException

/**
 * One desktop Vault switch on one of the owner's public lists: relays (10002), DM inbox (10050) or media servers
 * (10063). PLANS/NV_DESKTOP_VAULTS_PLAN.md §2.4 and §2.5 rule 7. iOS twin: `Services/Nostr/DesktopVaultListEdit.swift`
 * (P3 #2506).
 *
 * Every tap does the same three steps:
 * 1. fetch the newest list from the owner's relays;
 * 2. apply only this Vault's change to it ([DesktopVaultsLists.switching]);
 * 3. sign it and publish.
 *
 * It never republishes a list from this device's copy, so a switch can't drop a Vault entry or a hand-added relay
 * that another device added (Tron M2). When the lookup doesn't settle, nothing is signed and the switch snaps back
 * with [NOT_LOADED_MESSAGE]. The settled rule per list is the one its other editors use: 10002 and 10050 need both
 * indexers to answer ([RelayDraft.settled], as the Relays Save), 10063 goes through [ListMerge.editBase] (as
 * [publishMergedList]).
 *
 * There is no mesh relay (10002 `fipsmesh`) switch yet (Logen, 13:53Z): no caller turns one on. The screens that call
 * this are P7's.
 */
object DesktopVaultListEdit {
    private const val TAG = "DesktopVaultListEdit"

    sealed class Outcome {
        object Published : Outcome()
        /** The list already read that way: nothing was signed. */
        object Unchanged : Outcome()
        /** The relays couldn't say which list is newest: nothing was signed. */
        object NotLoaded : Outcome()
        /** The change would leave the list unusable: nothing was signed. */
        data class Refused(val list: DesktopVaultList) : Outcome()
        /** No signed-in account, the account changed during the lookup, or the signer said no. */
        object NotSigned : Outcome()

        /** The line the switch shows when it snaps back; null for a change that went out or had nothing to do. */
        val message: String?
            get() = when (this) {
                Published, Unchanged -> null
                NotLoaded -> NOT_LOADED_MESSAGE
                is Refused -> list.refusal
                NotSigned -> "Your list wasn't signed, so it wasn't changed."
            }
    }

    const val NOT_LOADED_MESSAGE = "Couldn't load your list, try again"

    /** The newest published list: its tags (null when the relays agree there is none) and the event, if any. */
    private class Base(val tags: List<List<String>>?, val event: NostrEvent?)

    /**
     * Turns [vault]'s [path] switch on [list] on or off. [vaults]: the Vaults whose entries count as Vault entries
     * (rules 1 and 2), the Desktop Vaults list by default.
     */
    suspend fun set(
        nostr: NostrService, on: Boolean, vault: DesktopVault, path: DesktopVaultPath, list: DesktopVaultList,
        vaults: List<DesktopVault> = nostr.configStore.config.value.desktopVaultsInEffect,
    ): Outcome {
        val owner = nostr.ownerHexPubkey.lowercase()
        if (owner.isBlank()) return Outcome.NotSigned
        val base = newest(nostr, list, owner) ?: return Outcome.NotLoaded
        // Never sign one account's list as another's.
        if (!nostr.ownerHexPubkey.equals(owner, ignoreCase = true)) return Outcome.NotSigned
        return when (val change = DesktopVaultsLists.switching(on, vault, path, list, base.tags, vaults)) {
            is DesktopVaultListChange.Refused -> Outcome.Refused(change.list)
            is DesktopVaultListChange.Tags ->
                if (change.tags == base.tags.orEmpty()) Outcome.Unchanged else publish(nostr, change.tags, list, owner, base.event)
        }
    }

    /** The newest list's tags for the switches to read (§2.1): [] when the relays agree there is none, null when not known. */
    suspend fun current(nostr: NostrService, list: DesktopVaultList): List<List<String>>? {
        val owner = nostr.ownerHexPubkey.lowercase()
        if (owner.isBlank()) return null
        return newest(nostr, list, owner)?.let { it.tags.orEmpty() }
    }

    private suspend fun newest(nostr: NostrService, list: DesktopVaultList, owner: String): Base? = when (list) {
        DesktopVaultList.RELAYS, DesktopVaultList.INBOX -> {
            val lookup = runCatching { nostr.lookupNewestReplaceable(list.kind, owner, nostr.relayListLookupRelays()) }.getOrNull()
            // Both indexers must answer: a lagging relay's older copy, re-signed, would roll the list back.
            if (lookup == null || !RelayDraft.settled(lookup.event != null, lookup.answeredBy, lookup.ahead)) null
            else Base(lookup.event?.tags, lookup.event)
        }
        DesktopVaultList.MEDIA -> {
            val own = nostr.ownListRelays(owner)
            val lookup = runCatching {
                nostr.lookupNewestReplaceable(10063, owner, (own + nostr.configStore.config.value.readRelays.take(3)).distinct())
            }.getOrNull()
            when (val b = lookup?.let { ListMerge.editBase(it, null, own) }) {
                is ListMerge.EditBase.Found -> Base(b.event.tags, b.event)
                ListMerge.EditBase.None -> Base(null, null)
                is ListMerge.EditBase.Unknown, null -> null
            }
        }
    }

    private suspend fun publish(
        nostr: NostrService, tags: List<List<String>>, list: DesktopVaultList, owner: String, base: NostrEvent?,
    ): Outcome {
        // Loopback entries never go out: nobody else can reach them.
        val out = if (list == DesktopVaultList.RELAYS) tags else tags.filterNot { it.size >= 2 && isLoopbackRelay(it[1]) }
        // Each kind spelled out, for the list sign guard.
        val event = try {
            when (list) {
                DesktopVaultList.RELAYS -> nostr.signEventAsync(kind = 10002, content = base?.content.orEmpty(), tags = out, forceOwner = true, notBefore = ListMerge.notBefore(base))
                DesktopVaultList.INBOX -> nostr.signEventAsync(kind = 10050, content = "", tags = out, forceOwner = true, notBefore = ListMerge.notBefore(base))
                DesktopVaultList.MEDIA -> nostr.signEventAsync(kind = 10063, content = "", tags = out, forceOwner = true, notBefore = ListMerge.notBefore(base))
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "kind ${list.kind} not signed: ${e.message}")
            null
        }
        if (event == null || !event.pubkey.equals(owner, ignoreCase = true)) return Outcome.NotSigned
        if (list == DesktopVaultList.INBOX) {
            nostr.configStore.update { it.copy(dmRelaysUpdatedAt = System.currentTimeMillis() / 1000) }
        }
        nostr.postEvent(event)
        // Ours is now the newest: Media Servers merges from it next time.
        if (list == DesktopVaultList.MEDIA) nostr.fetchServerList(owner)
        return Outcome.Published
    }
}
