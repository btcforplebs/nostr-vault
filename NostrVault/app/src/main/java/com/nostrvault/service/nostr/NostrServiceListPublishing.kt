package com.nostrvault.service

import android.util.Log
import com.nostrvault.BuildConfig
import com.nostrvault.relay.DMInbox
import com.nostrvault.relay.HavenConfig
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
            relays = HavenConfig.DEFAULT_DM_RELAYS
        }
        // NIP-17 tags are ["relay", url]. Builds before this wrote ["r", url],
        // which no other client reads — they saw an empty list and had nowhere
        // to deliver our DMs.
        val tags = relays.map { listOf("relay", it) }
        signAndPost(kind = 10050, content = "", tags = tags, forceOwner = true)
    }

    internal fun NostrService.publishMuteListImpl(accountNpub: String, blockedNpubs: List<String>) {
        val forceOwner = forceOwnerFor(accountNpub) ?: run {
            Log.w(TAG, "publishMuteList: ${accountNpub.take(12)} is not the owner or active account; not published")
            return
        }
        val tags = blockedNpubs.mapNotNull { npub ->
            npubToHex(npub)?.let { listOf("p", it) }
        }
        signAndPost(kind = 10000, content = "", tags = tags, forceOwner = forceOwner)
    }

    internal fun NostrService.publishRelayListImpl(accountNpub: String) {
        val forceOwner = forceOwnerFor(accountNpub) ?: run {
            Log.w(TAG, "publishRelayList: ${accountNpub.take(12)} is not the owner or active account; not published")
            return
        }
        val tags = configStore.config.value.publicRelayListTags
        if (tags.isEmpty()) return
        signAndPost(kind = 10002, content = "", tags = tags, forceOwner = forceOwner)
    }

    /**
     * Republishes kind 10050 for the owner account.
     *
     * Builds shipped a 10050 leading with 127.0.0.1, making those accounts
     * undeliverable — senders wrote the gift wrap to their own machine. 10050 is
     * replaceable, so publishing a clean one overwrites the broken one on every
     * relay holding it, and from then on *any* sender reaches them, including
     * ones still running the old build.
     */
    internal fun NostrService.republishDMRelayListImpl() {
        scope.launch(Dispatchers.IO) {
            runCatching { syncOwnerDMInboxList() }
                .onFailure { Log.w(TAG, "DM inbox sync failed: ${it.message}") }
        }
    }

    /**
     * Publishes this device's DM inbox list for the owner and stamps it as the
     * newest change. Call when the Haven relay address changes.
     */
    internal fun NostrService.publishOwnerDMInboxListImpl() {
        configStore.update { it.copy(dmRelaysUpdatedAt = System.currentTimeMillis() / 1000) }
        publishDMRelayList(configStore.config.value.dmInboxRelays)
    }

    /**
     * NIP-51: publishes the owner's blocked relay list (kind 10006), the relays
     * set to Never connect. An empty list is published too, so unblocking the
     * last relay clears it.
     */
    internal fun NostrService.publishBlockedRelayListImpl() {
        val tags = configStore.config.value.blockedRelays.map { listOf("relay", DMInbox.normalizedRelayURL(it)) }
        signAndPost(kind = 10006, content = "", tags = tags, forceOwner = true)
    }

    internal fun NostrService.publishServerListImpl() {
        val mirrors = configStore.config.value.activeBlossomMirrors
        if (mirrors.isEmpty()) return
        val tags = mirrors.map { listOf("server", it) }
        signAndPost(kind = 10063, content = "", tags = tags, forceOwner = true)
    }
