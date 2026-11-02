package com.nostrvault.service

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenBridge
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import javax.inject.Inject
import javax.inject.Singleton

/**
 * The active account's bookmarks (kind 10003): whether a note is one, the tap that adds or removes it, and what
 * the Bookmarks page lists. Reads the newest list from this device's vault and the account's relays; every change
 * goes through [publishBookmarkImpl], the merged-list path the other lists use. Twin of iOS `BookmarkService.swift`.
 */
@Singleton
class BookmarkService @Inject constructor(
    private val configStore: ConfigStore,
    private val nostrService: NostrService,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val readLock = Mutex()

    /** The newest list known for the active account; null when there is none yet. */
    private val _list = MutableStateFlow<NostrEvent?>(null)
    val list: StateFlow<NostrEvent?> = _list.asStateFlow()

    private val _saving = MutableStateFlow<Set<BookmarkList.Entry>>(emptySet())
    val saving: StateFlow<Set<BookmarkList.Entry>> = _saving.asStateFlow()

    @Volatile private var author = ""
    @Volatile private var loadedAt = 0L

    /** This device's vault first, then the account's own relays and a few read relays. */
    private suspend fun sources(hex: String): List<String> {
        val config = configStore.config.value
        return (listOfNotNull(config.localRelayURL("")) + nostrService.ownListRelays(hex) + config.readRelays.take(3)).distinct()
    }

    private fun eventOf(obj: JsonObject): NostrEvent? = runCatching {
        if (!HavenBridge.verifyEvent(obj.toString())) return null
        NostrEvent(
            id = obj["id"]!!.jsonPrimitive.content,
            pubkey = obj["pubkey"]!!.jsonPrimitive.content,
            createdAt = obj["created_at"]!!.jsonPrimitive.longOrNull!!,
            kind = obj["kind"]!!.jsonPrimitive.content.toInt(),
            tags = obj["tags"]?.jsonArray?.map { t -> t.jsonArray.map { it.jsonPrimitive.contentOrNull.orEmpty() } }.orEmpty(),
            content = obj["content"]?.jsonPrimitive?.contentOrNull.orEmpty(),
            sig = obj["sig"]!!.jsonPrimitive.content,
        )
    }.getOrNull()

    /** Reads the newest list again when it is older than five minutes or the account changed ([force] always). */
    suspend fun refresh(force: Boolean = false) = readLock.withLock {
        val hex = configStore.activeAccountHexPubkey.value
        if (hex.isEmpty()) { _list.value = null; author = ""; return@withLock }
        if (!force && hex == author && System.currentTimeMillis() - loadedAt < 300_000) return@withLock
        if (hex != author) _list.value = null
        author = hex
        val found = runCatching {
            nostrService.queryRawEvents(listOf("{\"kinds\":[${BookmarkList.KIND}],\"authors\":[\"$hex\"],\"limit\":5}"), sources(hex))
        }.getOrDefault(emptyList()).mapNotNull(::eventOf)
        if (configStore.activeAccountHexPubkey.value != hex) return@withLock
        val newest = found.filter { it.pubkey == hex && it.kind == BookmarkList.KIND }
            .maxWithOrNull(compareBy<NostrEvent> { it.createdAt }.thenByDescending { it.id })
        if (newest != null && newest.createdAt >= (_list.value?.createdAt ?: 0)) _list.value = newest
        loadedAt = System.currentTimeMillis()
    }

    fun refreshInBackground() { scope.launch { refresh() } }

    fun entry(id: String, pubkey: String, kind: Int, tags: List<List<String>>) = BookmarkList.entry(id, pubkey, kind, tags)

    fun isBookmarked(list: NostrEvent?, entry: BookmarkList.Entry): Boolean =
        list != null && list.pubkey == configStore.activeAccountHexPubkey.value && BookmarkList.contains(list.tags, entry)

    val canSign: Boolean get() = !nostrService.isReadOnlyAccount() &&
        nostrService.forceOwnerFor(configStore.config.value.activeOrOwnerNpub()) != null

    /**
     * Adds or removes [entry] on the newest list fetched now; [onDone] gets what to tell the person, on the main thread.
     * Never runs for a read-only sign-in.
     */
    fun toggle(entry: BookmarkList.Entry, onDone: (String) -> Unit) {
        if (!canSign) return
        val hex = configStore.activeAccountHexPubkey.value
        val npub = configStore.config.value.activeOrOwnerNpub()
        val forceOwner = nostrService.forceOwnerFor(npub) ?: return
        if (hex.isEmpty() || entry in _saving.value) return
        val on = !isBookmarked(_list.value, entry)
        _saving.update { it + entry }
        scope.launch {
            val tell: suspend (String) -> Unit = { msg -> withContext(Dispatchers.Main) { onDone(msg) } }
            val result = nostrService.publishBookmarkImpl(entry, on, hex, forceOwner)
            _saving.update { it - entry }
            when (result) {
                is BookmarkList.Publish.Saved -> {
                    if (configStore.activeAccountHexPubkey.value == hex && result.event.pubkey == hex) {
                        _list.value = result.event
                        loadedAt = System.currentTimeMillis()
                    }
                    tell(if (on) "Bookmarked" else "Bookmark removed")
                }
                is BookmarkList.Publish.Unchanged -> {
                    if (result.base != null && configStore.activeAccountHexPubkey.value == hex && result.base.pubkey == hex) {
                        _list.value = result.base
                    }
                    tell(if (on) "Bookmarked" else "Bookmark removed")
                }
                is BookmarkList.Publish.Failed -> tell("Bookmark not saved: ${result.why ?: "your relays didn't answer"}")
            }
        }
    }

    /** The private bookmarks, decrypted with the active account's key; empty when none or they can't be opened here. */
    suspend fun privateEntries(): List<BookmarkList.Entry> {
        val list = _list.value ?: return emptyList()
        if (list.content.isEmpty() || list.pubkey != configStore.activeAccountHexPubkey.value) return emptyList()
        val plain = runCatching { nostrService.decryptOwnList(list.pubkey, list.content, list.content.contains("?iv=")) }
            .getOrNull() ?: return emptyList()
        return BookmarkList.privateEntries(plain)
    }

    /** The events behind [entries], by entry, from the vault and the relays. */
    suspend fun events(entries: List<BookmarkList.Entry>): Map<BookmarkList.Entry, NostrEvent> {
        val hex = configStore.activeAccountHexPubkey.value
        val urls = sources(hex)
        val out = mutableMapOf<BookmarkList.Entry, NostrEvent>()
        val ids = entries.filterIsInstance<BookmarkList.Entry.Event>().map { it.id }
        for (chunk in ids.chunked(100)) {
            val filter = "{\"ids\":[${chunk.joinToString(",") { "\"$it\"" }}]}"
            runCatching { nostrService.queryRawEvents(listOf(filter), urls) }.getOrDefault(emptyList())
                .mapNotNull(::eventOf).filter { it.id in chunk }
                .forEach { out[BookmarkList.Entry.Event(it.id)] = it }
        }
        // Addresses grouped by kind and author; a filter matches every combination of its values, so each
        // result is checked against a wanted coordinate.
        val wanted = entries.filterIsInstance<BookmarkList.Entry.Address>().toSet()
        val groups = wanted.mapNotNull { it.parts }.groupBy { it.first to it.second }
        for ((key, coords) in groups) {
            val ds = coords.joinToString(",") { "\"${it.third.replace("\\", "\\\\").replace("\"", "\\\"")}\"" }
            val filter = "{\"kinds\":[${key.first}],\"authors\":[\"${key.second}\"],\"#d\":[$ds]}"
            runCatching { nostrService.queryRawEvents(listOf(filter), urls) }.getOrDefault(emptyList())
                .mapNotNull(::eventOf).forEach { ev ->
                    val entry = BookmarkList.entry(ev.id, ev.pubkey, ev.kind, ev.tags)
                    if (entry in wanted && (out[entry]?.createdAt ?: -1) < ev.createdAt) out[entry] = ev
                }
        }
        return out
    }
}
