package com.nostrvault.service

import android.content.Context
import android.util.Log
import com.nostrvault.data.local.ConfigStore
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

/**
 * The account's own custom emoji, read from Nostr and never written here:
 * the newest kind 10030 (NIP-51), its single `emoji` tags, and the 30030 sets
 * its `a` tags add. Cached on disk so the picker has them at once; refreshed
 * at launch and whenever the picker opens. Saving to 10030 is a later step.
 */
@Singleton
class EmojiListRepository @Inject constructor(
    private val nostrService: NostrService,
    private val configStore: ConfigStore,
    @ApplicationContext private val context: Context,
) {
    @Serializable
    data class EmojiSet(val address: String, val title: String, val emojis: List<CustomEmoji>)

    /** [owner]'s emoji: [single] saved one by one, then whole [sets]. */
    @Serializable
    data class Library(
        val owner: String = "",
        val single: List<CustomEmoji> = emptyList(),
        val sets: List<EmojiSet> = emptyList(),
    ) {
        val isEmpty: Boolean get() = single.isEmpty() && sets.all { it.emojis.isEmpty() }
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val json = Json { ignoreUnknownKeys = true }
    private val cacheFile get() = File(context.filesDir, "emoji_library.json")

    private val _library = MutableStateFlow(Library())
    val library: StateFlow<Library> = _library.asStateFlow()

    private var refreshing: Job? = null
    private var lastRefreshMs = 0L

    init {
        scope.launch {
            runCatching { json.decodeFromString(Library.serializer(), cacheFile.readText()) }
                .getOrNull()
                ?.let { if (_library.value.owner.isEmpty()) _library.value = it }
        }
    }

    /** Asks the relays again, at most once a minute. Shows nothing of another account's. */
    fun refresh() {
        val owner = nostrService.activeHexPubkey
        if (owner.isEmpty()) return
        if (_library.value.owner.isNotEmpty() && _library.value.owner != owner) _library.value = Library(owner)
        val now = System.currentTimeMillis()
        if (refreshing?.isActive == true || now - lastRefreshMs < REFRESH_EVERY_MS) return
        lastRefreshMs = now
        refreshing = scope.launch {
            runCatching { load(owner) }
                .onFailure { Log.w(TAG, "emoji list not loaded: ${it.message}") }
                .getOrNull()
                ?.let { loaded ->
                    if (nostrService.activeHexPubkey != owner) return@launch
                    _library.value = loaded
                    runCatching { cacheFile.writeText(json.encodeToString(Library.serializer(), loaded)) }
                }
        }
    }

    private suspend fun load(owner: String): Library? {
        val ask = askRelays(owner)
        val list = nostrService.lookupNewestReplaceable(10030, owner, ask).event ?: return null
        val parsed = EmojiListParse.list(list.tags)
        val sets = kotlinx.coroutines.coroutineScope {
            parsed.setAddresses.take(MAX_SETS).map { address ->
                async {
                    val ref = EmojiListParse.setRef(address) ?: return@async null
                    val event = nostrService.lookupNewestReplaceable(
                        30030, ref.pubkey, ask + askRelays(ref.pubkey), dTag = ref.d,
                    ).event ?: return@async null
                    EmojiListParse.set(address, event.tags)
                }
            }.awaitAll().filterNotNull()
        }
        return Library(owner, parsed.single, sets)
    }

    private fun askRelays(pubkey: String): List<String> =
        (nostrService.relayLists.value[pubkey].orEmpty() + configStore.config.value.readRelays +
            NostrService.PROFILE_RELAYS).distinct()

    private companion object {
        const val TAG = "EmojiList"
        const val REFRESH_EVERY_MS = 60_000L
        /** Sets fetched per refresh; each is a lookup across the relays. */
        const val MAX_SETS = 20
    }
}

/** Reading kinds 10030 and 30030. Pure, so it is testable apart from the relays. */
object EmojiListParse {
    data class ListTags(val single: List<CustomEmoji>, val setAddresses: List<String>)
    data class SetRef(val pubkey: String, val d: String)

    /** A 10030's tags: valid `emoji` tags (first per shortcode) and its 30030 `a` refs. */
    fun list(tags: List<List<String>>): ListTags = ListTags(
        single = CustomEmoji.fromTags(tags).values.toList(),
        setAddresses = tags.filter { it.size >= 2 && it[0] == "a" && setRef(it[1]) != null }
            .map { it[1] }.distinct(),
    )

    /** `30030:<64 hex>:<d>`, or null. */
    fun setRef(address: String): SetRef? {
        val parts = address.split(":", limit = 3)
        if (parts.size != 3 || parts[0] != "30030") return null
        if (!parts[1].matches(Regex("^[0-9a-f]{64}$"))) return null
        return SetRef(parts[1], parts[2])
    }

    /** A 30030's title and emoji, each tagged with the set's [address]. */
    fun set(address: String, tags: List<List<String>>): EmojiListRepository.EmojiSet {
        val title = tags.firstOrNull { it.size >= 2 && it[0] == "title" }?.get(1)?.takeIf { it.isNotBlank() }
            ?: tags.firstOrNull { it.size >= 2 && it[0] == "d" }?.get(1)?.takeIf { it.isNotBlank() }
            ?: "Emoji set"
        val emojis = CustomEmoji.fromTags(tags).values.map { it.copy(setAddress = address) }
        return EmojiListRepository.EmojiSet(address, title, emojis)
    }
}
