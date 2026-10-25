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
        val lookup = lookupNewestReplaceable(10050, owner, config.dmInboxRelays)
        // No relay answered: "none found" is unknown, not empty. A new install
        // of an existing account would otherwise publish the defaults over
        // the real list.
        if (lookup.event == null && lookup.answered == 0) {
            Log.w(TAG, "DM inbox sync: no relay answered; not published")
            return
        }
        val newest = lookup.event?.let { profileRepository.parseDMRelayListTags(it.tags) to it.createdAt }
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
        val author = npubToHex(accountNpub) ?: ownerHexPubkey
        val blocked = blockedNpubs.mapNotNull { npubToHex(it) }
        // The "p" tags are this device's blocks. The rest of the published
        // list (word, hashtag and thread mutes, and the encrypted private
        // mutes in content) was set in other clients and is kept.
        publishMergedList(10000, author, forceOwner) { published ->
            ListMerge.tags("p", blocked, published?.tags.orEmpty()) { false } to published?.content.orEmpty()
        }
    }

    /**
     * Publishes [kind] for [author] built by [build] from the newest
     * published one (null when there is none). Skips when no relay answered,
     * since publishing then would overwrite a list this device never saw.
     */
    private fun NostrService.publishMergedList(
        kind: Int,
        author: String,
        forceOwner: Boolean,
        extraRelays: () -> List<String> = { emptyList() },
        build: (NostrEvent?) -> Pair<List<List<String>>, String>?,
    ) {
        if (author.isBlank()) return
        scope.launch(Dispatchers.IO) {
            val lookup = runCatching {
                lookupNewestReplaceable(kind, author, configStore.config.value.readRelays.take(3))
            }.getOrElse { NostrService.ReplaceableLookup(null, 0, 0) }
            if (lookup.event == null && lookup.answered == 0) {
                Log.w(TAG, "kind $kind: no relay answered; not published")
                return@launch
            }
            val (tags, content) = build(lookup.event) ?: run {
                Log.w(TAG, "kind $kind: nothing that may be published; not published")
                return@launch
            }
            val extra = extraRelays()
            if (extra.isEmpty()) {
                signAndPost(kind = kind, content = content, tags = tags, forceOwner = forceOwner)
                return@launch
            }
            val event = try {
                signEventAsync(kind = kind, content = content, tags = tags, forceOwner = forceOwner)
            } catch (e: Exception) {
                Log.e(TAG, "kind $kind not signed: ${e.message}")
                null
            } ?: return@launch
            postEvent(event)
            extra.forEach { fireAndForgetPublish(event, it) }
        }
    }

    /**
     * Publishes [kind] for the owner: [local] as [name] tags, plus the
     * entries other clients added. An entry counts as added elsewhere when
     * it is published but was not in what this device last published (the
     * base kept in [ListMerge.Bases]), so a local removal still removes it.
     */
    private fun NostrService.publishOwnerEntryList(
        kind: Int,
        name: String,
        local: List<String>,
        extraRelays: () -> List<String> = { emptyList() },
        adjust: (List<List<String>>) -> List<List<String>>? = { it },
    ) {
        val owner = ownerHexPubkey
        val bases = configStore.config.value.appSupportDir?.let { ListMerge.Bases(java.io.File(it, ListMerge.BASES_FILE)) }
        val baseKey = "$kind:$owner"
        publishMergedList(kind, owner, forceOwner = true, extraRelays = extraRelays) { published ->
            val base = bases?.get(baseKey)?.map(ListMerge::key)?.toSet()
            val tags = ListMerge.tags(name, local, published?.tags.orEmpty()) { base == null || ListMerge.key(it) !in base }
            // Null: [adjust] refused the list. Nothing goes out, so the base stays what was last published.
            val adjusted = adjust(tags) ?: return@publishMergedList null
            bases?.put(baseKey, local)
            adjusted to published?.content.orEmpty()
        }
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
        val relays = configStore.config.value.blockedRelays.map(DMInbox::normalizedRelayURL)
        publishOwnerEntryList(10006, "relay", relays)
    }

    internal fun NostrService.publishServerListImpl(dropMesh: Collection<String> = emptyList()) {
        val config = configStore.config.value
        val mirrors = config.activeBlossomMirrors
        val home = config.homeVaultNpub
        val macs = linkedMacs(config)
        if (mirrors.isEmpty() && home == null && macs.isEmpty() && dropMesh.isEmpty()) return
        // Every fipsmesh:// entry on the published list is kept (a kiosk put
        // it there), after the public servers; this phone's home vault and
        // linked Macs are added and the ones it listed before ([dropMesh])
        // removed. With no public server nothing is published (NIP-F1).
        // Every write relay the owner's 10002 names, and purplepag.es, not only this phone's broadcast
        // list: readers look a 10063 up on the author's write relays (Logen 2026-10-22: each list landed
        // on one relay).
        val extraRelays = {
            ServerListRelays.extra(_outboxRelays.value[ownerHexPubkey], config.activeBlastrRelays)
        }
        publishOwnerEntryList(10063, "server", mirrors, extraRelays) { tags ->
            val servers = tags.filter { it.size >= 2 && it[0] == "server" }.map { it[1] }
            val merged = com.nostrvault.fips.HomeVaultRules.mergeServerList(
                servers, servers, home, dropMesh, macs, myDevices = config.fipsPeers,
            ) ?: return@publishOwnerEntryList null
            merged.map { listOf("server", it) } + tags.filter { it.isNotEmpty() && it[0] != "server" }
        }
    }

    /** The Macs in My Devices this phone lists in the owner's 10063 (iOS 8af86b0d). */
    internal fun linkedMacs(config: com.nostrvault.relay.HavenConfig): List<String> =
        com.nostrvault.fips.MeshSendTargets.of(config).filter { it.role == com.nostrvault.fips.DeviceRole.MAC }.map { it.npub }

/** Where a 10063 goes besides the broadcast relays. Pure for the tests. */
internal object ServerListRelays {
    const val INDEX_RELAY = "wss://purplepag.es"

    /**
     * The owner's published 10002 write relays and purplepag.es, minus what the broadcast already
     * reaches ([broadcast]) and loopback addresses; compared without case or a trailing slash.
     */
    fun extra(publishedWrite: List<String>?, broadcast: List<String>): List<String> {
        fun key(url: String) = url.trim().trimEnd('/').lowercase()
        val sent = broadcast.map(::key).toMutableSet()
        return (publishedWrite.orEmpty() + INDEX_RELAY)
            .filter { it.startsWith("wss://") || it.startsWith("ws://") }
            .filter { !NostrService.isLoopbackRelay(it) }
            .filter { sent.add(key(it)) }
    }
}

/**
 * Merging this device's entries into a list published by any client. NIP-51
 * lists are replaceable, so publishing only what this device holds deletes
 * everything another client added.
 */
internal object ListMerge {
    const val BASES_FILE = "list_publish_bases.json"

    /** Compares entries regardless of case, padding and a trailing slash. */
    fun key(value: String): String = value.trim().trimEnd('/').lowercase()

    /**
     * [local] as `[name, value]` tags, then the [published] tags kept: every
     * tag of another name, and a [name] tag that is not local when
     * [keepPublished] says so.
     */
    fun tags(
        name: String,
        local: List<String>,
        published: List<List<String>>,
        keepPublished: (String) -> Boolean,
    ): List<List<String>> {
        val seen = HashSet<String>()
        val mine = local.filter { it.isNotBlank() && seen.add(key(it)) }.map { listOf(name, it) }
        val kept = published.filter { tag ->
            when {
                tag.isEmpty() -> false
                tag[0] != name -> true
                else -> tag.size >= 2 && keepPublished(tag[1]) && seen.add(key(tag[1]))
            }
        }
        return mine + kept
    }

    /**
     * What this device last published per list, so the next publish can tell
     * an entry another client added from one removed here. A list with no
     * base yet (the first publish after this shipped) keeps every published
     * entry: a removal made in that one publish stays on the published list,
     * which only other clients read, rather than another client's entries
     * being wiped.
     */
    class Bases(private val file: java.io.File) {
        private val json = Json { ignoreUnknownKeys = true }
        private val serializer = kotlinx.serialization.serializer<Map<String, List<String>>>()

        fun get(key: String): List<String>? = synchronized(Bases::class) { read()[key] }

        fun put(key: String, entries: List<String>) = synchronized(Bases::class) {
            runCatching { file.writeText(json.encodeToString(serializer, read() + (key to entries))) }
                .onFailure { Log.w(TAG, "list base not saved: ${it.message}") }
            Unit
        }

        private fun read(): Map<String, List<String>> =
            runCatching { json.decodeFromString(serializer, file.readText()) }.getOrDefault(emptyMap())
    }
}
