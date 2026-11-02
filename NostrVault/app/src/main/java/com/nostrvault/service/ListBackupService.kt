package com.nostrvault.service

import android.content.Context
import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.RelayForegroundService
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
    @Volatile private var author = ""

    private suspend fun signAuth(url: String, challenge: String): NostrEvent? = runCatching {
        nostrService.signEventAsync(
            kind = 22242,
            content = "",
            tags = listOf(listOf("relay", url), listOf("challenge", challenge)),
            forceOwner = true,
        )
    }.getOrNull()

    /** Reads every kept version for the active account from the vault. */
    suspend fun load() {
        val hex = configStore.activeAccountHexPubkey.value
        val config = configStore.config.value
        if (hex.isEmpty() || config.useExternalRelay || !RelayForegroundService.readyForConnections.value) {
            _state.value = State.UNAVAILABLE
            return
        }
        val url = config.localRelayURL("lists") ?: run { _state.value = State.UNAVAILABLE; return }
        if (author != hex) {
            _groups.value = emptyMap()
            events = emptyMap()
        }
        author = hex
        _state.value = State.LOADING
        val filter = "{\"authors\":[\"$hex\"],\"kinds\":${ListShrinkRule.protectedKinds},\"limit\":1000}"
        var found = runCatching { VaultSocket.query(url, filter, { signAuth(url, it) }) }.getOrNull()
        // At the limit the relay cut the oldest, which may be a pinned list from before a wipe:
        // ask again one kind at a time (Tron, PR 1568).
        if (found != null && found.size >= 1000) {
            val all = mutableListOf<NostrEvent>()
            for (kind in ListShrinkRule.protectedKinds) {
                val one = "{\"authors\":[\"$hex\"],\"kinds\":[$kind],\"limit\":1000}"
                val some = runCatching { VaultSocket.query(url, one, { signAuth(url, it) }) }.getOrNull()
                if (some == null) { found = null; break }
                all += some
            }
            if (found != null) found = all
        }
        if (configStore.activeAccountHexPubkey.value != hex) return
        if (found == null) {
            _state.value = State.UNAVAILABLE
            return
        }
        events = found.associateBy { it.id }
        _groups.value = ListHistory.group(found.map(ListVersion::of), hex)
        _state.value = State.LOADED
    }

    /** Wipes the newest version of a list made that the person hasn't dismissed, newest first. */
    fun wipes(groups: Map<ListHistory.Key, List<ListVersion>>, dismissed: Set<String>): List<Pair<ListHistory.Key, ListHistory.Wipe>> =
        groups.mapNotNull { (key, versions) ->
            ListHistory.latestWipe(versions)?.takeIf { ListHistory.worthABanner(it) && it.after.id !in dismissed }?.let { key to it }
        }.sortedByDescending { it.second.after.createdAt }

    /** "Keep the new list": this wipe is not shown again. */
    fun dismiss(wipe: ListHistory.Wipe) {
        _dismissed.update { it + wipe.after.id }
        prefs.edit().putStringSet(DISMISSED, _dismissed.value).apply()
    }

    private fun vaultEvents(v: ListVersion): List<NostrEvent> =
        _groups.value[ListHistory.Key(v.kind, v.d)].orEmpty().mapNotNull { events[it.id] }

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
     * what to tell them. One rule for every list (RESEARCH/NV_LIST_PROTECTION_PLAN.md):
     * 1. the newest list is fetched again and must match what was shown;
     * 2. the vault must hold that newest list first, so the restore can be undone;
     * 3. the old tags are signed by the same account, dated after the newest; kind 3 keeps the newest content;
     * 4. the vault must accept it, then it goes to the person's relays;
     * 5. the app's follow list and mutes are reloaded.
     * Never called without a tap.
     */
    suspend fun restore(old: ListVersion, shown: Preview): String? {
        val error = restoreList(old, shown)
        load()
        return error
    }

    private suspend fun restoreList(old: ListVersion, shown: Preview): String? {
        val name = ListShrinkRule.name(old.kind)
        val npub = configStore.config.value.activeOrOwnerNpub()
        if (configStore.activeAccountHexPubkey.value != old.pubkey) return "This list belongs to another account. Switch to it first."
        val forceOwner = nostrService.forceOwnerFor(npub) ?: return "This list belongs to another account. Switch to it first."
        val config = configStore.config.value
        val vaultUrl = config.localRelayURL("") ?: return "Your vault isn't running. Nothing was changed."
        val current = currentList(old).getOrElse { return it.message ?: "Your newest $name can't be checked. Nothing was changed." }
        if (current?.id != shown.current?.id) return "Your $name changed while this was open. Nothing was changed; look again and retry."
        if (current != null && current.id == old.id) return "This version is already your newest $name."
        val kept = vaultEvents(old)
        if (current != null && kept.none { it.id == current.id } &&
            !VaultSocket.publish(vaultUrl, current, { signAuth(vaultUrl, it) })
        ) {
            return "Your vault couldn't keep a copy of your newest $name, so the restore couldn't be undone. Nothing was changed."
        }
        val (tags, content) = ListHistory.restored(old, current?.let(ListVersion::of))
        val signed = try {
            nostrService.signEventAsync(kind = old.kind, content = content, tags = tags, forceOwner = forceOwner,
                notBefore = ListMerge.notBefore(current))
        } catch (e: Exception) {
            Log.e(TAG, "restore of kind ${old.kind} not signed: ${e.message}")
            null
        }
        if (signed == null || signed.pubkey != old.pubkey) return "The list couldn't be signed. Nothing was changed."
        if (configStore.activeAccountHexPubkey.value != old.pubkey) return "You switched accounts during the restore. Nothing was changed."
        if (!VaultSocket.publish(vaultUrl, signed, { signAuth(vaultUrl, it) })) {
            return "Your vault refused the restored $name. Nothing was sent to your relays."
        }
        // postEvent sends through the active account's relays: still this one?
        if (configStore.activeAccountHexPubkey.value != old.pubkey) {
            return "You switched accounts during the restore. Your vault kept the restored list; this app didn't send it to your relays. Switch back and check it."
        }
        nostrService.postEvent(signed)
        when (old.kind) {
            3 -> runCatching { feedService.refreshContactList() }
            10000 -> runCatching { nostrService.applyMuteList(signed.pubkey, signed.id, signed.tags, signed.content, signed.createdAt) }
        }
        return null
    }

    private companion object {
        const val TAG = "ListBackupService"
        const val DISMISSED = "dismissed_wipes"
    }
}
