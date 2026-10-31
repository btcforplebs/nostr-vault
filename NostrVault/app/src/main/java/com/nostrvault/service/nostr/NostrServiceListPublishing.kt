package com.nostrvault.service

import android.util.Log
import com.nostrvault.BuildConfig
import com.nostrvault.data.model.MuteList
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
     * Takes the owner's newest published DM inbox list (kind 10050) when it
     * is newer than this device's. Never publishes: launch and setup used to
     * publish this device's list, or the app's defaults when the account had
     * none, without the owner saving anything (Logen 2026-10-31). Only Save
     * in Settings > Relays publishes it. See [DMInbox].
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

        val action = DMInbox.syncAction(config.dmInboxRelays, config.dmRelaysUpdatedAt, published, newest?.second)
        if (action == DMInbox.SyncAction.ADOPT && newest != null && published != null) {
            configStore.updateAsync {
                it.copy(dmRelays = published.ifEmpty { it.dmRelays }, dmRelaysUpdatedAt = newest.second)
            }
            if (BuildConfig.DEBUG) Log.i(TAG, "Adopted published DM inbox list (${published.size} relays)")
        }
    }

    /**
     * The owner's published relay list (kind 10002) and DM inbox (kind
     * 10050), for Settings > Relays. A list counts as known when both
     * indexer relays answered ([com.nostrvault.relay.RelayDraft.settled]); otherwise the cached copy
     * is shown and Save won't publish over it.
     */
    internal suspend fun NostrService.lookupOwnerRelayListsImpl(): com.nostrvault.relay.RelayDraft.Published =
        lookupRelayListsImpl(ownerHexPubkey)

    /** [lookupOwnerRelayListsImpl] for any account, by hex pubkey. */
    internal suspend fun NostrService.lookupRelayListsImpl(owner: String): com.nostrvault.relay.RelayDraft.Published = coroutineScope {
        if (owner.isBlank()) return@coroutineScope com.nostrvault.relay.RelayDraft.Published()
        val config = configStore.config.value
        val ask = (config.writeRelays + config.readRelays.take(3) + NostrService.PROFILE_RELAYS + com.nostrvault.relay.RelayDraft.INDEXERS)
            .filterNot(::isLoopbackRelay).distinctBy(com.nostrvault.relay.RelayMatrix::key)
        val relayList = async { runCatching { lookupNewestReplaceable(10002, owner, ask) }.getOrNull() }
        val dmList = async {
            runCatching {
                lookupNewestReplaceable(10050, owner, (ask + config.dmInboxRelays).filterNot(::isLoopbackRelay).distinctBy(com.nostrvault.relay.RelayMatrix::key))
            }.getOrNull()
        }
        val rl = relayList.await()
        val dl = dmList.await()
        val (read, write) = rl?.event?.let { profileRepository.parseRelayListTags(it.tags) }
            ?: (relayLists.value[owner].orEmpty() to outboxRelays.value[owner].orEmpty())
        val dms = dl?.event?.let { profileRepository.parseDMRelayListTags(it.tags) } ?: emptyList()
        // Entries the screen can't edit (ws://, home network) stay as published; loopback ones are dropped, they
        // never worked for anyone.
        val kept = rl?.event?.tags.orEmpty().filter {
            it.size >= 2 && it[0] == "r" && !com.nostrvault.relay.RelayDraft.listable(it[1]) && !isLoopbackRelay(it[1])
        }
        com.nostrvault.relay.RelayDraft.Published(
            read = read.filter(com.nostrvault.relay.RelayDraft::listable),
            write = write.filter(com.nostrvault.relay.RelayDraft::listable),
            dms = dms.filterNot(::isLoopbackRelay),
            relayListKnown = rl != null && com.nostrvault.relay.RelayDraft.settled(rl.event != null, rl.answeredBy),
            dmListKnown = dl != null && com.nostrvault.relay.RelayDraft.settled(dl.event != null, dl.answeredBy),
            kept = kept,
        ).also {
            Log.i(TAG, "Relay lists looked up: 10002 ${rl?.answered}/${rl?.asked} found=${rl?.event != null}, " +
                "10050 ${dl?.answered}/${dl?.asked} found=${dl?.event != null}")
        }
    }

    /** Publishes [tags] as the owner's kind 10002. Only Save in Settings > Relays calls this. */
    internal fun NostrService.publishOwnerRelayListTagsImpl(tags: List<List<String>>) {
        signAndPost(kind = 10002, content = "", tags = tags, forceOwner = true)
    }

    /**
     * Takes the owner's published media server list (kind 10063, set in
     * another app) as this device's upload servers, in their order. See
     * [ServerListAdoption]. Nothing is published here.
     */
    internal suspend fun NostrService.syncOwnerServerList() {
        val owner = ownerHexPubkey
        if (owner.isBlank()) return
        val config = configStore.config.value
        val ask = (config.writeRelays + config.readRelays + NostrService.PROFILE_RELAYS).filterNot(::isLoopbackRelay).distinct()
        val event = lookupNewestReplaceable(10063, owner, ask).event ?: return
        val base = config.appSupportDir?.let { ListMerge.Bases(java.io.File(it, ListMerge.BASES_FILE)) }?.get("10063:$owner")
        val own = listOf(config.macRelayHttpsURL).filter { it.isNotBlank() }
        var added = emptyList<String>()
        configStore.updateAsync { current ->
            val result = ServerListAdoption.adopt(
                current.blossomMirrors, current.blossomMirrorsUpdatedAt,
                profileRepository.parseServerListTags(event.tags), event.createdAt, base, own,
            ) ?: return@updateAsync current
            added = result.added
            current.copy(blossomMirrors = result.mirrors, blossomMirrorsUpdatedAt = result.updatedAt)
        }
        if (added.isNotEmpty()) Log.i(TAG, "Adopted ${added.size} media server(s) from the published kind 10063")
    }

    fun NostrService.publishDMRelayList(dmRelays: List<String>) {
        // A kind 10050 is a PUBLIC announcement of where others should deliver
        // DMs to us. The embedded Haven relay lives on 127.0.0.1 and is never
        // reachable by anyone else, so loopback URLs must be stripped — otherwise
        // senders are told to deliver replies to an address they can't reach.
        // Exactly what the owner saved: an emptied list goes out empty rather
        // than as the app's defaults, or the removed relays come back on the
        // next launch's adopt.
        val relays = dmRelays.filter { !isLoopbackRelay(it) }
        // NIP-17 tags are ["relay", url]. Builds before this wrote ["r", url],
        // which no other client reads — they saw an empty list and had nowhere
        // to deliver our DMs.
        val tags = relays.map { listOf("relay", it) }
        signAndPost(kind = 10050, content = "", tags = tags, forceOwner = true)
    }

    /**
     * Blocks ([add]) or unblocks ([remove]) people, by npub, on [accountNpub]'s
     * kind 10000, a list other clients edit too. Only those entries change on
     * the newest list: everyone else on it, the muted words, hashtags and
     * threads, and the encrypted private part are kept. [localBlocks], this
     * device's public blocks after the change, is published only when the
     * account has no list anywhere. Returns what to tell the person when
     * nothing was published (the list couldn't be fetched, or wasn't signed).
     * [privateBefore] is the account's private blocks before an unblock took
     * the person off this device's list.
     */
    internal suspend fun NostrService.publishMuteListChangeImpl(
        accountNpub: String,
        add: List<String>,
        remove: List<String>,
        localBlocks: List<String>,
        privateBefore: Collection<String> = emptyList(),
    ): String? {
        val forceOwner = forceOwnerFor(accountNpub) ?: run {
            Log.w(TAG, "publishMuteList: ${accountNpub.take(12)} is not the owner or active account; not published")
            return null
        }
        val author = npubToHex(accountNpub) ?: ownerHexPubkey
        if (author.isBlank()) return null
        val action = if (add.isEmpty()) "Unblock" else "Block"
        val cfg = configStore.config.value
        // The relays the mute list is read from at sign-in, so a block builds
        // on the list another app last wrote, not an older copy, and the
        // write relays editBase needs to hear from.
        val ask = (cfg.writeRelays + relayLists.value[author].orEmpty() + cfg.readRelays + NostrService.PROFILE_RELAYS).distinct()
        val lookup = runCatching { lookupNewestReplaceable(10000, author, ask) }
            .getOrElse { NostrService.ReplaceableLookup(null, 0, 0) }
        // Private blocks stay in the encrypted content, never in the "p" tags.
        val private = cfg.privateBlockedNpubsPerAccount[accountNpub.ifEmpty { cfg.ownerNpub }].orEmpty().toSet()
        val (baseTags, baseContent) = when (val base = ListMerge.editBase(lookup, heldMuteList(author), cfg.writeRelays.filterNot(::isLoopbackRelay))) {
            is ListMerge.EditBase.Found -> base.event.tags to base.event.content
            ListMerge.EditBase.None -> localBlocks.filter { it !in private }.mapNotNull { npubToHex(it) }.map { listOf("p", it) } to ""
            ListMerge.EditBase.Unknown -> {
                Log.w(TAG, "kind 10000: list not fetched (${lookup.answered}/${lookup.asked} relays answered); not published")
                return "$action saved on this device only: your relays didn't send your mute list, " +
                    "and publishing without it would erase blocks set in other apps. Try again later."
            }
        }
        val removeHex = remove.mapNotNull { npubToHex(it) }
        // An unblock takes the person out of the encrypted part too, or
        // reading the published list back blocks them again.
        val content = when (
            val edited = ListMerge.removingPrivate(
                baseContent, removeHex,
                knownPrivate = remove.any { it in private || it in privateBefore },
                decrypt = { text, nip04 -> decryptOwnList(author, text, nip04) },
                encrypt = { text, nip04 -> encryptOwnList(author, text, nip04) },
            )
        ) {
            ListMerge.PrivateEdit.Failed -> return "$action saved on this device only: your private blocks couldn't be updated"
            is ListMerge.PrivateEdit.Done -> edited.content
        }
        val tags = ListMerge.edit("p", baseTags, add.mapNotNull { npubToHex(it) }, removeHex)
        val event = try {
            signEventAsync(kind = 10000, content = content, tags = tags, forceOwner = forceOwner)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.e(TAG, "kind 10000 not signed: ${e.message}")
            null
        } ?: return "$action saved on this device only: your signer didn't answer"
        postEvent(event)
        // This device's blocks become the published list, so people another
        // app blocked show as blocked here too.
        applyMuteList(author, event.id, event.tags, event.content, event.createdAt)
        return null
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
        onPosted: () -> Unit = {},
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
            val event = try {
                signEventAsync(kind = kind, content = content, tags = tags, forceOwner = forceOwner)
            } catch (e: Exception) {
                Log.e(TAG, "kind $kind not signed: ${e.message}")
                null
            } ?: return@launch
            postEvent(event)
            extra.forEach { fireAndForgetPublish(event, it) }
            onPosted()
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
        publishedFirst: Boolean = false,
        onPosted: () -> Unit = {},
        adjust: (List<List<String>>) -> List<List<String>>? = { it },
    ) {
        val owner = ownerHexPubkey
        val bases = configStore.config.value.appSupportDir?.let { ListMerge.Bases(java.io.File(it, ListMerge.BASES_FILE)) }
        val baseKey = "$kind:$owner"
        publishMergedList(kind, owner, forceOwner = true, extraRelays = extraRelays, onPosted = onPosted) { published ->
            val base = bases?.get(baseKey)?.map(ListMerge::key)?.toSet()
            val keep = { value: String -> base == null || ListMerge.key(value) !in base }
            val tags = if (publishedFirst) {
                ListMerge.tagsPublishedFirst(name, local, published?.tags.orEmpty(), keep)
            } else {
                ListMerge.tags(name, local, published?.tags.orEmpty(), keep)
            }
            // Null: [adjust] refused the list. Nothing goes out, so the base stays what was last published.
            val adjusted = adjust(tags) ?: return@publishMergedList null
            bases?.put(baseKey, local)
            adjusted to published?.content.orEmpty()
        }
    }


    /** Runs [syncOwnerDMInboxList] off the main thread: adopts a newer published 10050, never publishes. */
    internal fun NostrService.adoptPublishedDMRelayListImpl() {
        scope.launch(Dispatchers.IO) {
            runCatching { syncOwnerDMInboxList() }
                .onFailure { Log.w(TAG, "DM inbox sync failed: ${it.message}") }
        }
    }

    /**
     * The owner saved a new Haven relay address: on the published DM inbox
     * list, [oldInbox] becomes [newInbox] and every other entry stays as
     * published. Nothing goes out when no list was found or the indexers
     * didn't both answer, so the app's defaults never reach it and a lagging
     * relay's older copy is never re-signed over a newer one (Tron, #1386).
     */
    internal fun NostrService.publishOwnerDMInboxMoveImpl(oldInbox: String, newInbox: String) {
        val owner = ownerHexPubkey
        if (owner.isBlank()) return
        scope.launch(Dispatchers.IO) {
            val config = configStore.config.value
            val ask = (config.dmInboxRelays + config.writeRelays + com.nostrvault.relay.RelayDraft.INDEXERS)
                .filterNot(::isLoopbackRelay).distinctBy(com.nostrvault.relay.RelayMatrix::key)
            val lookup = runCatching { lookupNewestReplaceable(10050, owner, ask) }.getOrNull()
            val event = lookup?.event?.takeIf { com.nostrvault.relay.RelayDraft.settled(true, lookup.answeredBy) } ?: run {
                Log.w(TAG, "DM inbox move: no settled published list; not published")
                return@launch
            }
            val tags = ListMerge.edit("relay", event.tags, listOfNotNull(newInbox.ifBlank { null }), listOfNotNull(oldInbox.ifBlank { null }))
            if (tags == event.tags) return@launch
            configStore.update { it.copy(dmRelaysUpdatedAt = System.currentTimeMillis() / 1000) }
            signAndPost(kind = 10050, content = "", tags = tags, forceOwner = true)
        }
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
        // What unlinks left for this Save to take off (FipsMeshViewModel records them; Tron #1451).
        val drop = (dropMesh + config.serverListDropMesh).distinct()
        if (mirrors.isEmpty() && home == null && macs.isEmpty() && drop.isEmpty()) return
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
        // Their published order stays first (BUD-03: the first server is their default); a server
        // only this device has goes after it.
        // Cleared only once the list went out, so a Save that published nothing drops them next time.
        val cleared = { configStore.update { it.copy(serverListDropMesh = it.serverListDropMesh - drop.toSet()) } }
        publishOwnerEntryList(10063, "server", mirrors, extraRelays, publishedFirst = true, onPosted = cleared) { tags ->
            val servers = tags.filter { it.size >= 2 && it[0] == "server" }.map { it[1] }
            val merged = com.nostrvault.fips.HomeVaultRules.mergeServerList(
                servers, servers, home, drop, macs, myDevices = config.fipsPeers,
            ) ?: return@publishOwnerEntryList null
            merged.map { listOf("server", it) } + tags.filter { it.isNotEmpty() && it[0] != "server" }
        }
    }

    /**
     * The mesh npubs the next Save takes off the owner's 10063 after a My Devices change from [before] to
     * [after]: the [pending] ones plus the home vault or linked Macs that went, less any listed again.
     */
    internal fun serverListDropsAfter(
        before: com.nostrvault.relay.HavenConfig,
        after: com.nostrvault.relay.HavenConfig,
        pending: List<String> = after.serverListDropMesh,
    ): List<String> {
        val listedBefore = listOfNotNull(before.homeVaultNpub) + linkedMacs(before)
        val listedAfter = (listOfNotNull(after.homeVaultNpub) + linkedMacs(after)).toSet()
        return (pending + listedBefore).distinct().filter { it !in listedAfter }
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
     * The [published] tags first, in their order: every tag of another name,
     * a [name] tag that is [local], and one that is not when [keepPublished]
     * says so. Then the [local] entries not already there, in order. For a
     * list whose first entry means something (a 10063's default server), so
     * a device's own order never moves the owner's.
     */
    fun tagsPublishedFirst(
        name: String,
        local: List<String>,
        published: List<List<String>>,
        keepPublished: (String) -> Boolean,
    ): List<List<String>> {
        val localKeys = local.filter { it.isNotBlank() }.map(::key).toSet()
        val seen = HashSet<String>()
        val kept = published.filter { tag ->
            when {
                tag.isEmpty() -> false
                tag[0] != name -> true
                else -> tag.size >= 2 && tag[1].isNotBlank() &&
                    (key(tag[1]) in localKeys || keepPublished(tag[1])) && seen.add(key(tag[1]))
            }
        }
        val mine = local.filter { it.isNotBlank() && seen.add(key(it)) }.map { listOf(name, it) }
        return kept + mine
    }

    /**
     * A block or unblock on a list other clients edit too: every [base] tag
     * kept as it is, the [name] tags for [remove] taken out, and [add] put at
     * the end unless already there. Replacing the whole [name] part with this
     * device's entries dropped people another app had just added.
     */
    fun edit(name: String, base: List<List<String>>, add: List<String>, remove: List<String>): List<List<String>> {
        val removed = remove.map(::key).toSet()
        val out = base.filterNot { it.size >= 2 && it[0] == name && key(it[1]) in removed }.toMutableList()
        val present = out.filter { it.size >= 2 && it[0] == name }.map { key(it[1]) }.toMutableSet()
        for (value in add) {
            if (value.isNotBlank() && key(value) !in removed && present.add(key(value))) out += listOf(name, value)
        }
        return out
    }

    /**
     * The private part of a kind 10000 with people taken out: the decrypted
     * [plaintext] without the "p" entries for [remove] (hex), as JSON again.
     * Null when no one in [remove] is in it, or when it is not exactly a JSON
     * array of string arrays: writing it back would then lose what it holds.
     */
    fun privateRemoved(plaintext: String, remove: List<String>): String? {
        val array = runCatching { Json.parseToJsonElement(plaintext) as? JsonArray }.getOrNull() ?: return null
        val tags = array.map { item ->
            val tag = item as? JsonArray ?: return null
            tag.map { value -> (value as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return null }
        }
        val edited = edit("p", tags, emptyList(), remove)
        if (edited.size == tags.size) return null
        return JsonArray(edited.map { tag -> JsonArray(tag.map(::JsonPrimitive)) }).toString()
    }

    /** What an unblock leaves in the encrypted content. */
    sealed interface PrivateEdit {
        data class Done(val content: String) : PrivateEdit
        /**
         * The person may be in the private part but it couldn't be rewritten
         * and checked: publishing would leave them blocked, or lose the part.
         */
        data object Failed : PrivateEdit
    }

    /**
     * [content] with [remove] (hex) taken out of its encrypted "p" entries,
     * encrypted again with the scheme it came in: NIP-04 when it has "?iv=",
     * else NIP-44. [decrypt] and [encrypt] take the text and whether it is
     * NIP-04, and return null when this device can't. Unchanged only when no
     * one in [remove] is in it, or when it can't be opened and [knownPrivate]
     * (this device holds one of them as a private block) is false. The new
     * content is opened again with [decrypt] and must give back the edited
     * part in the same scheme, so a signer that echoes the plaintext or uses
     * another key or account never gets published.
     */
    suspend fun removingPrivate(
        content: String,
        remove: List<String>,
        knownPrivate: Boolean,
        decrypt: suspend (String, Boolean) -> String?,
        encrypt: suspend (String, Boolean) -> String?,
    ): PrivateEdit {
        val ciphertext = content.trim()
        if (remove.isEmpty() || ciphertext.isEmpty()) return PrivateEdit.Done(content)
        val nip04 = MuteList.isNip04(ciphertext)
        val plaintext = attempt { decrypt(ciphertext, nip04) }
            ?: return if (knownPrivate) PrivateEdit.Failed else PrivateEdit.Done(content)
        val edited = privateRemoved(plaintext, remove) ?: run {
            // What reading the list back sees: if it still has them,
            // publishing this content blocks them again.
            val read = MuteList.privateTags(plaintext).orEmpty()
            return if (edit("p", read, emptyList(), remove).size < read.size) PrivateEdit.Failed else PrivateEdit.Done(content)
        }
        val encrypted = attempt { encrypt(edited, nip04) }
        if (encrypted.isNullOrBlank() || MuteList.isNip04(encrypted) != nip04) return PrivateEdit.Failed
        return if (attempt { decrypt(encrypted, nip04) } == edited) PrivateEdit.Done(encrypted) else PrivateEdit.Failed
    }

    /** [block]'s result, or null when it throws; cancellation still cancels. */
    private suspend fun attempt(block: suspend () -> String?): String? = try {
        block()
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        null
    }

    /** What an edit builds on. */
    sealed interface EditBase {
        /** The newest list, published or already held here. */
        data class Found(val event: NostrEvent) : EditBase
        /** Every relay answered and none has a list. */
        data object None : EditBase
        /** Not known: publishing could replace a list this device never saw. */
        data object Unknown : EditBase
    }

    /**
     * The newest of the list the relays returned and the one this device
     * already [held]. Unknown when no relay answered, when no list turned up
     * and some relay didn't answer, or when none of the account's [own]
     * relays was heard from: neither sent the list nor every one answered.
     * A copy on another relay alone can be older than the one on [own].
     */
    fun editBase(lookup: NostrService.ReplaceableLookup, held: NostrEvent?, own: Collection<String> = emptyList()): EditBase {
        if (lookup.answered == 0) return EditBase.Unknown
        val mine = own.map(::relayKey).toSet()
        val ownHeard = mine.isEmpty() || lookup.answeredBy.map(::relayKey).containsAll(mine) ||
            lookup.from.any { relayKey(it) in mine }
        if (!ownHeard) return EditBase.Unknown
        val newest = listOfNotNull(lookup.event, held).maxByOrNull { it.createdAt }
        return when {
            newest != null -> EditBase.Found(newest)
            lookup.confirmedNone -> EditBase.None
            else -> EditBase.Unknown
        }
    }

    private fun relayKey(url: String): String = url.trim().lowercase().trimEnd('/')

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
