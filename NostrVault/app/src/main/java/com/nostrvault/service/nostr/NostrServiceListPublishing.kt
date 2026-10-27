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

    /**
     * Adds the servers on the owner's published media server list (kind
     * 10063, set in another app) to this device's upload servers. See
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

    /**
     * Blocks ([add]) or unblocks ([remove]) people, by npub, on [accountNpub]'s
     * kind 10000, a list other clients edit too. Only those entries change on
     * the newest list: everyone else on it, the muted words, hashtags and
     * threads, and the encrypted private part are kept. [localBlocks], this
     * device's public blocks after the change, is published only when the
     * account has no list anywhere. Returns what to tell the person when
     * nothing was published (the list couldn't be fetched, or wasn't signed).
     */
    internal suspend fun NostrService.publishMuteListChangeImpl(
        accountNpub: String,
        add: List<String>,
        remove: List<String>,
        localBlocks: List<String>,
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
        val content = when (val edited = privateRemoved(author, baseContent, removeHex)) {
            PrivateEdit.Failed -> return "$action saved on this device only: your signer didn't update your private blocks"
            is PrivateEdit.Done -> edited.content
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
        applyMuteList(author, event.tags, event.content, event.createdAt)
        return null
    }

    private sealed interface PrivateEdit {
        class Done(val content: String) : PrivateEdit
        data object Failed : PrivateEdit
    }

    /**
     * [content] with the [remove] hex pubkeys taken out of its encrypted "p"
     * entries, encrypted the same way again. Unchanged when no one in
     * [remove] is in it, or when this device can't open it: then reading
     * the list back can't re-block them either.
     */
    private suspend fun NostrService.privateRemoved(hex: String, content: String, remove: List<String>): PrivateEdit {
        if (remove.isEmpty() || content.isBlank()) return PrivateEdit.Done(content)
        val nip04 = MuteList.isNip04(content)
        val plaintext = runCatching { decryptOwnList(hex, content, nip04) }.getOrNull()
        val privateTags = plaintext?.let(MuteList::privateTags) ?: return PrivateEdit.Done(content)
        val edited = ListMerge.edit("p", privateTags, emptyList(), remove)
        if (edited.size == privateTags.size) return PrivateEdit.Done(content)
        val json = JsonArray(edited.map { tag -> JsonArray(tag.map(::JsonPrimitive)) }).toString()
        val ciphertext = runCatching { encryptOwnList(hex, json, nip04) }.getOrNull()
        return ciphertext?.let { PrivateEdit.Done(it) } ?: PrivateEdit.Failed
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
        build: (NostrEvent?) -> Pair<List<List<String>>, String>,
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
            val (tags, content) = build(lookup.event)
            signAndPost(kind = kind, content = content, tags = tags, forceOwner = forceOwner)
        }
    }

    /**
     * Publishes [kind] for the owner: [local] as [name] tags, plus the
     * entries other clients added. An entry counts as added elsewhere when
     * it is published but was not in what this device last published (the
     * base kept in [ListMerge.Bases]), so a local removal still removes it.
     */
    private fun NostrService.publishOwnerEntryList(kind: Int, name: String, local: List<String>) {
        val owner = ownerHexPubkey
        val bases = configStore.config.value.appSupportDir?.let { ListMerge.Bases(java.io.File(it, ListMerge.BASES_FILE)) }
        val baseKey = "$kind:$owner"
        publishMergedList(kind, owner, forceOwner = true) { published ->
            val base = bases?.get(baseKey)?.map(ListMerge::key)?.toSet()
            val tags = ListMerge.tags(name, local, published?.tags.orEmpty()) { base == null || ListMerge.key(it) !in base }
            bases?.put(baseKey, local)
            tags to published?.content.orEmpty()
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

    internal fun NostrService.publishServerListImpl() {
        val mirrors = configStore.config.value.activeBlossomMirrors
        if (mirrors.isEmpty()) return
        publishOwnerEntryList(10063, "server", mirrors)
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
