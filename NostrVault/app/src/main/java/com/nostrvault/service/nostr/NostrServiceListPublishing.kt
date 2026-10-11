package com.nostrvault.service

import android.util.Log
import com.nostrvault.BuildConfig
import com.nostrvault.relay.DMInbox
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import com.nostrvault.service.NostrService.Companion.TAG
import com.nostrvault.service.NostrService.Companion.isLoopbackRelay

    // ══════════════════════════════════════════════════════════════════
    // Specialized event publishing
    // ══════════════════════════════════════════════════════════════════

    /**
     * Which key signs a list "for [accountNpub]": the owner's (forceOwner) or the
     * active account's. null means neither can — another, inactive account —
     * and publishing must be skipped rather than overwrite a different
     * identity's replaceable list with this one's.
     */
    internal fun NostrService.forceOwnerFor(accountNpub: String): Boolean? {
        val cfg = configStore.config.value
        return when (accountNpub) {
            "", cfg.ownerNpub -> true
            cfg.activeOrOwnerNpub() -> false
            else -> null
        }
    }

    /**
     * Brings the owner's DM inbox list (kind 10050) into step across devices:
     * the newest published list is adopted unless this device published a
     * newer one, in which case ours is published. Every device used to
     * republish its own settings at launch, so whichever device opened last
     * silently replaced the list the others had set. See [DMInbox].
     */
    internal suspend fun NostrService.syncOwnerDMInboxList() {
        val owner = ownerHexPubkey
        if (owner.isBlank()) return
        val config = configStore.config.value
        val newest = fetchNewestDMRelayList(owner, config.dmInboxRelays)
        val published = newest?.first?.filter { !isLoopbackRelay(it) }

        var action = DMInbox.syncAction(config.dmInboxRelays, config.dmRelaysUpdatedAt, published, newest?.second)
        if (action == DMInbox.SyncAction.ADOPT && newest != null && published != null) {
            configStore.updateAsync {
                it.copy(dmRelays = published.ifEmpty { it.dmRelays }, dmRelaysUpdatedAt = newest.second)
            }
            if (BuildConfig.DEBUG) Log.i(TAG, "Adopted published DM inbox list (${published.size} relays)")
            // This device may still hold more than was published (its own
            // Haven inbox, or loopback entries dropped).
            action = DMInbox.syncAction(configStore.config.value.dmInboxRelays, newest.second, newest.first, newest.second)
        }
        if (action == DMInbox.SyncAction.PUBLISH) publishOwnerDMInboxList()
    }

    fun NostrService.publishDMRelayList(dmRelays: List<String>) {
        // A kind 10050 is a PUBLIC announcement of where others should deliver
        // DMs to us. The embedded Haven relay lives on 127.0.0.1 and is never
        // reachable by anyone else, so loopback URLs must be stripped — otherwise
        // senders are told to deliver replies to an address they can't reach.
        var relays = dmRelays.filter { !isLoopbackRelay(it) }
        // Never publish an empty list — fall back to public defaults.
        if (relays.isEmpty()) {
            relays = listOf(
                "wss://relay.primal.net",
                "wss://nos.lol",
                "wss://relay.btcforplebs.com",
            )
        }
        // NIP-17 tags are ["relay", url]. Builds before this wrote ["r", url],
        // which no other client reads — they saw an empty list and had nowhere
        // to deliver our DMs.
        val tags = relays.map { listOf("relay", it) }
        signAndPost(kind = 10050, content = "", tags = tags, forceOwner = true)
    }
