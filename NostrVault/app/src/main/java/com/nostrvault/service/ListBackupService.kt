package com.nostrvault.service

import android.content.Context
import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.MuteList
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.relay.vaultAuthRelayTag
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import javax.inject.Inject
import javax.inject.Singleton

/**
 * The active account's list versions kept by the vault (its /lists relay),
 * for the List backups screens and the wipe banner, and the one restore rule.
 * Following Backup keeps its own on-device follow snapshots; this is the
 * vault's copy of every list. Twin of iOS `ListBackupService.swift` and
 * `NostrService+ListRestore.swift`.
 */
@Singleton
class ListBackupService @Inject constructor(
    @ApplicationContext private val context: Context,
    private val configStore: ConfigStore,
    private val nostrService: NostrService,
    private val feedService: FeedService,
) {
    enum class State { IDLE, LOADING, LOADED, UNAVAILABLE }

    /** What a restore would change, against the newest list known when the page opened. */
    data class Preview(val current: NostrEvent?, val comeBack: Set<String>, val go: Set<String>, val replacesPrivate: Boolean)

    private val _state = MutableStateFlow(State.IDLE)
    val state: StateFlow<State> = _state.asStateFlow()

    /** Every kept version per list, newest first. */
    private val _groups = MutableStateFlow<Map<ListHistory.Key, List<ListVersion>>>(emptyMap())
    val groups: StateFlow<Map<ListHistory.Key, List<ListVersion>>> = _groups.asStateFlow()

    private val prefs = context.getSharedPreferences("list_backups", Context.MODE_PRIVATE)
    private val _dismissed = MutableStateFlow(prefs.getStringSet(DISMISSED, emptySet()).orEmpty().toSet())
    val dismissed: StateFlow<Set<String>> = _dismissed.asStateFlow()

    @Volatile private var events: Map<String, NostrEvent> = emptyMap()

    /** The ids of the versions an import filed ([ListHistoryScan]): shown, never judged by the wipe alarm. */
    private val _importedIds = MutableStateFlow<Set<String>>(emptySet())
    val importedIds: StateFlow<Set<String>> = _importedIds.asStateFlow()
    @Volatile private var author = ""

    private suspend fun signAuth(url: String, challenge: String): NostrEvent? = runCatching {
        nostrService.signEventAsync(
            kind = 22242,
            content = "",
            tags = listOf(listOf("relay", configStore.config.value.vaultAuthRelayTag(url)), listOf("challenge", challenge)),
            forceOwner = true,
        )
    }.getOrNull()

    /** Reads every kept version for the active account from the vault. */
    suspend fun load() {
        val hex = configStore.activeAccountHexPubkey.value
        if (hex.isEmpty() || !vaultReady()) {
            _state.value = State.UNAVAILABLE
            return
        }
        if (author != hex) {
            _groups.value = emptyMap()
            events = emptyMap()
            _importedIds.value = emptySet()
        }
        author = hex
        _state.value = State.LOADING
        val own = fetch(hex)
        // No answer for the imported ones (an older vault): only the own.
        val imported = if (own != null) fetch(hex, imported = true).orEmpty() else emptyList()
        if (configStore.activeAccountHexPubkey.value != hex) return
        if (own == null) {
            _state.value = State.UNAVAILABLE
            return
        }
        val ownIds = own.mapTo(HashSet()) { it.id }
        val importedOnly = imported.filter { it.id !in ownIds }
        val found = own + importedOnly
        _importedIds.value = importedOnly.mapTo(HashSet()) { it.id }
        events = found.associateBy { it.id }
        _groups.value = ListHistory.group(found.map(ListVersion::of), hex)
        _state.value = State.LOADED
    }

    private fun vaultReady(): Boolean =
        !configStore.config.value.useExternalRelay && RelayForegroundService.readyForConnections.value

    /**
     * Every kept version of [hex]'s lists, grouped, for the wipe alarm
     * ([ListWipeWatcher]): any account this vault serves, not only the active
     * one. Null when the vault can't be read. Leaves the banner's state alone.
     */
    suspend fun versionsOf(hex: String): Map<ListHistory.Key, List<ListVersion>>? {
        if (hex.isEmpty() || !vaultReady()) return null
        val found = fetch(hex) ?: return null
        return ListHistory.group(found.map(ListVersion::of), hex)
    }

    /**
     * Every version the vault filed itself for [hex] or, with [imported], every one a moving-in import
     * filed (haven-go wantsImported); null when it can't be read.
     */
    private suspend fun fetch(hex: String, imported: Boolean = false): List<NostrEvent>? {
        val url = configStore.config.value.localRelayURL("lists") ?: return null
        val tag = if (imported) ",\"#v\":[\"${ListHistoryScan.IMPORTED_FILTER_VALUE}\"]" else ""
        val filter = "{\"authors\":[\"$hex\"],\"kinds\":${ListShrinkRule.protectedKinds},\"limit\":1000$tag}"
        var found = runCatching { VaultSocket.query(url, filter, { signAuth(url, it) }) }.getOrNull()
        // At the limit the relay cut the oldest, which may be a pinned list from before a wipe:
        // ask again one kind at a time (Tron, PR 1568).
        if (found != null && found.size >= 1000) {
            val all = mutableListOf<NostrEvent>()
            for (kind in ListShrinkRule.protectedKinds) {
                val one = "{\"authors\":[\"$hex\"],\"kinds\":[$kind],\"limit\":1000$tag}"
                val some = runCatching { VaultSocket.query(url, one, { signAuth(url, it) }) }.getOrNull() ?: return null
                all += some
            }
            found = all
        }
        return found
    }

    /**
     * The wipe alarms for the lists in [groups] the person hasn't dismissed, newest first
     * ([ListWipeAlarmRule]; versions this app signed never alarm). Only the versions the vault
     * filed itself are judged, never the [imported] ones (Tron, PR 1639).
     */
    fun wipes(
        groups: Map<ListHistory.Key, List<ListVersion>>,
        dismissed: Set<String>,
        imported: Set<String> = _importedIds.value,
    ): List<Pair<ListHistory.Key, ListWipeAlarmRule.Alarm>> =
        ListWipeAlarmRule.alarms(ListHistoryScan.alarmInput(groups, imported), OwnListEdits.ids(), dismissed)

    /** Whether [versions] of one list raise a wipe alarm, judging only the vault's own (the list row's mark). */
    fun wiped(versions: List<ListVersion>): Boolean {
        val imported = _importedIds.value
        return ListWipeAlarmRule.alarm(versions.filterNot { it.id in imported }, OwnListEdits.ids(), emptySet()) != null
    }

    /** "Keep the new list": this alarm is not shown again. */
    fun dismiss(alarm: ListWipeAlarmRule.Alarm) {
        _dismissed.update { it + alarm.after.id }
        prefs.edit().putStringSet(DISMISSED, _dismissed.value).apply()
    }

    /**
     * The versions of [v]'s list the vault filed itself, newest first: what a restore or merge counts as
     * held (an imported copy is not the vault's undo copy; web keepUndoCopy reads the same way).
     */
    private fun vaultEvents(v: ListVersion): List<NostrEvent> {
        val imported = _importedIds.value
        return _groups.value[ListHistory.Key(v.kind, v.d)].orEmpty().filterNot { it.id in imported }.mapNotNull { events[it.id] }
    }

    /**
     * The newest copy of [old]'s list from the account's own relays and the
     * vault, with the rule every list edit uses ([ListMerge.editBase]).
     * Failure carries what to tell the person.
     */
    private suspend fun currentList(old: ListVersion): Result<NostrEvent?> {
        val own = nostrService.ownListRelays(old.pubkey)
        val lookup = runCatching {
            nostrService.lookupNewestReplaceable(
                old.kind, old.pubkey, (own + configStore.config.value.readRelays.take(3)).distinct(),
                dTag = if (old.kind >= 30000) old.d else null,
            )
        }.getOrElse { NostrService.ReplaceableLookup(null, 0, 0) }
        return when (val base = ListMerge.editBase(lookup, vaultEvents(old).firstOrNull(), own)) {
            is ListMerge.EditBase.Found -> Result.success(base.event)
            ListMerge.EditBase.None -> Result.success(null)
            is ListMerge.EditBase.Unknown -> Result.failure(IllegalStateException(base.why))
        }
    }

    /** What restoring [old] would bring back and take away, against the newest list as fetched now. */
    suspend fun preview(old: ListVersion): Result<Preview> = currentList(old).map { current ->
        val now = current?.let(ListVersion::of)
        val (comeBack, go) = ListHistory.diff(old, now)
        Preview(current, comeBack, go, ListHistory.replacesPrivatePart(old, now))
    }

    /**
     * Restores [old] after the person confirmed [shown]; null when done, else
     * what to tell them. The old tags go through the one safe save ([ListVersionSave]);
     * kind 3 keeps the newest content. Never called without a tap.
     */
    suspend fun restore(old: ListVersion, shown: Preview): String? {
        val error = restoreList(old, shown)
        load()
        return error
    }

    private suspend fun restoreList(old: ListVersion, shown: Preview): String? {
        val saverFor = saver(old.pubkey).getOrElse { return it.message }
        val outcome = saverFor(old).save(
            old.pubkey, old.kind, shown.current?.id, "restore",
            refuse = { current -> if (current != null && current.id == old.id) "This version is already your newest ${ListShrinkRule.name(old.kind)}." else null },
        ) { current ->
            val (tags, content) = ListHistory.restored(old, current?.let(ListVersion::of))
            ListVersionSave.Build.Ready(tags, content)
        }
        return (outcome as? ListVersionSave.Outcome.Refused)?.message
    }

    /** The Merge page's start: the newest list now, opened, and every version of it, older ones locked. */
    data class MergeStart(
        val current: ListVersionMerge.Opened?,
        /** The newest list is known; else [why] says why not and nothing can be merged. */
        val checked: Boolean,
        val why: String,
        /** Newest first, the current one included. */
        val versions: List<ListVersionMerge.Opened>,
        /**
         * The versions the vault keeps with no hole between them ([ListVersionMerge.unbroken]); a current found only on relays isn't one.
         * No default: empty means "nothing unbroken", unlike [ListVersionMerge.buildMerge]'s null ("all").
         */
        val vault: Set<String>,
    )

    /**
     * Opens [key]'s versions for merging. Only the newest list is decrypted here; an older one's private part
     * waits for its tick ([opener]), so a signer isn't asked once per version just to look.
     */
    suspend fun mergeStart(key: ListHistory.Key): MergeStart {
        val kept = _groups.value[key].orEmpty()
        val ref = kept.firstOrNull() ?: return MergeStart(null, false, "No versions of this list are kept yet.", emptyList(), vault = emptySet())
        val found = currentList(ref)
        val now = found.getOrNull()?.let(ListVersion::of)
        val all = (listOfNotNull(now) + kept).distinctBy { it.id }.sortedWith(ListHistory.newerFirst)
        val opener = opener(ref.pubkey)
        val versions = all.map { ListVersionMerge.openVersion(it, if (it.id == now?.id) opener else ListVersionMerge.Opener.Later) }
        return MergeStart(
            current = versions.firstOrNull { it.v.id == now?.id },
            checked = found.isSuccess,
            why = found.exceptionOrNull()?.message.orEmpty(),
            versions = versions,
            // Only the vault's own run has no holes; an imported one may (web unbroken()).
            vault = ListVersionMerge.unbroken(kept.filterNot { it.id in _importedIds.value }),
        )
    }

    /** Opens [pubkey]'s own private list parts, NIP-04 by its "?iv=" marker else NIP-44, as the mute list does. */
    fun opener(pubkey: String): ListVersionMerge.Opener =
        ListVersionMerge.Opener.With { ciphertext -> nostrService.decryptOwnList(pubkey, ciphertext, MuteList.isNip04(ciphertext)) }

    /**
     * Saves the merge [rows] built on [current] (null: there was none) for [key], after the person confirmed it,
     * through the one safe save ([ListVersionSave], [ListMergeSave]). Never called without a tap.
     */
    suspend fun saveMerge(
        key: ListHistory.Key,
        current: ListVersionMerge.Opened?,
        authors: Set<String>,
        rows: List<ListVersionMerge.Row>,
    ): ListVersionSave.Outcome {
        val (tags, privateTags) = ListVersionMerge.mergedTags(rows, current)
        ListMergeSave.refusal(key.kind, current?.v, current != null && !current.unread, tags, privateTags)
            ?.let { return ListVersionSave.Outcome.Refused(it) }
        val list = current?.v ?: _groups.value[key]?.firstOrNull()
            ?: return ListVersionSave.Outcome.Refused("No versions of this list are kept. Nothing was changed.")
        ListMergeSave.authorRefusal(list.pubkey, authors)?.let { return ListVersionSave.Outcome.Refused(it) }
        val saverFor = saver(list.pubkey).getOrElse { return ListVersionSave.Outcome.Refused(it.message.orEmpty()) }
        val outcome = saverFor(list).save(list.pubkey, key.kind, current?.v?.id, "merge") { now ->
            ListMergeSave.build(
                key.kind, now, tags, privateTags,
                encrypt = { text, nip04 -> nostrService.encryptOwnList(list.pubkey, text, nip04) },
                decrypt = { text, nip04 -> nostrService.decryptOwnList(list.pubkey, text, nip04) },
            )
        }
        load()
        return outcome
    }

    /** Profiles already known to the app, for naming people in a merge. */
    val profiles get() = nostrService.profiles

    /** Asks the relays for the profiles of [pubkeys] the app doesn't know yet, so people show by name and picture. */
    fun fetchProfiles(pubkeys: List<String>) { if (pubkeys.isNotEmpty()) nostrService.fetchMissingProfiles(pubkeys) }

    /**
     * The safe save for a new version of [pubkey]'s list ([ListVersionSave]), wired to this
     * account's signer, vault and relays; a failure carries what to tell the person.
     */
    private fun saver(pubkey: String): Result<(ListVersion) -> ListVersionSave> {
        val npub = configStore.config.value.activeOrOwnerNpub()
        val other = "This list belongs to another account. Switch to it first."
        if (configStore.activeAccountHexPubkey.value != pubkey) return Result.failure(IllegalStateException(other))
        val forceOwner = nostrService.forceOwnerFor(npub) ?: return Result.failure(IllegalStateException(other))
        val vaultUrl = configStore.config.value.localRelayURL("")
            ?: return Result.failure(IllegalStateException("Your vault isn't running. Nothing was changed."))
        return Result.success { list ->
            ListVersionSave(object : ListVersionSave.Steps {
                override fun activeAccount() = configStore.activeAccountHexPubkey.value
                override suspend fun newest() = currentList(list)
                override suspend fun keepUndoCopy(current: NostrEvent) =
                    vaultEvents(list).any { it.id == current.id } || VaultSocket.publish(vaultUrl, current, { signAuth(vaultUrl, it) })
                override suspend fun sign(kind: Int, content: String, tags: List<List<String>>, notBefore: Long) = try {
                    nostrService.signEventAsync(kind = kind, content = content, tags = tags, forceOwner = forceOwner, notBefore = notBefore)
                } catch (e: Exception) {
                    Log.e(TAG, "new version of kind $kind not signed: ${e.message}")
                    null
                }
                override suspend fun store(signed: NostrEvent) = VaultSocket.publish(vaultUrl, signed, { signAuth(vaultUrl, it) })
                override suspend fun send(signed: NostrEvent) {
                    nostrService.postEvent(signed)
                    when (signed.kind) {
                        3 -> runCatching { feedService.refreshContactList() }
                        10000 -> runCatching { nostrService.applyMuteList(signed.pubkey, signed.id, signed.tags, signed.content, signed.createdAt) }
                    }
                }
            })
        }
    }

    private companion object {
        const val TAG = "ListBackupService"
        const val DISMISSED = "dismissed_wipes"
    }
}
