package com.nostrvault.service

import android.content.Context
import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.remote.LookupSocketPool
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.RelayConfiguration
import com.nostrvault.relay.RelayForegroundService
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Loads, caches and publishes the active account's interest list (kind
 * 10015): the hashtags it follows. Port of iOS `InterestListService`.
 *
 * Never publishes against a list it hasn't seen: each publish fetches the
 * newest list first and edits that. No list found counts as "none" only
 * when every relay asked answered; otherwise the change is put back. State lives on Main, like the iOS `@MainActor` service.
 */
@Singleton
class InterestListService @Inject constructor(
    @ApplicationContext private val context: Context,
    private val configStore: ConfigStore,
    private val nostrService: NostrService,
    private val lookupPool: LookupSocketPool,
) {
    companion object {
        private const val TAG = "InterestList"
        private const val PREFS_NAME = "interest_lists"
        private const val FETCH_TIMEOUT_MS = 6_000L
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    private val json = Json { ignoreUnknownKeys = true }

    private val _hashtags = MutableStateFlow<List<String>>(emptyList())
    /** Followed hashtags for the active account. */
    val hashtags: StateFlow<List<String>> = _hashtags.asStateFlow()

    private var list = InterestList()
    private var accountHex = ""
    /** True once this account's list is known (found, or every relay answered none). */
    private var confirmed = false
    private var fetch: Deferred<Boolean>? = null
    /**
     * Why the last change wasn't saved because the list isn't known ([ListMerge.NO_RELAY_LIST] or
     * [ListMerge.NOT_ANSWERED]), for the screen to say; null when it was known.
     */
    @Volatile var refusal: String? = null
        private set

    init {
        scope.launch { configStore.activeAccountHexPubkey.collect { switchAccount(it) } }
    }

    /** What a "Couldn't save" dialog says: why, when there's no relay list; else that the relays didn't answer. */
    fun failedText(): String = if (refusal == ListMerge.NO_RELAY_LIST) ListMerge.NO_RELAY_LIST
        else "Your relays didn't answer, so your hashtag list wasn't changed. Try again in a moment."

    fun isFollowing(hashtag: String): Boolean = InterestList.normalize(hashtag) in _hashtags.value

    /** Fetches the latest list from relays once per account. */
    fun refreshIfNeeded() {
        scope.launch {
            if (accountHex.isEmpty() || confirmed || fetch != null) return@launch
            startFetch()
        }
    }

    /**
     * Follows or unfollows a hashtag and publishes the new list. Shows the
     * change at once; puts it back if the relays' copy can't be read or the
     * event can't be signed. Returns false when nothing was published.
     */
    suspend fun setFollowing(hashtag: String, followed: Boolean): Boolean = setFollowing(listOf(hashtag), followed)

    /** [setFollowing] for several hashtags at once, as one published list. */
    suspend fun setFollowing(hashtags: List<String>, followed: Boolean): Boolean = withContext(Dispatchers.Main.immediate) {
        val hex = accountHex
        val names = hashtags.map { InterestList.normalize(it) }.filter { it.isNotEmpty() }
        if (hex.isEmpty() || names.isEmpty()) return@withContext false
        fun applied(base: InterestList) = names.fold(base) { acc, name -> acc.setting(name, followed) }

        // Optimistic: the button flips now.
        _hashtags.value = applied(list).hashtags

        // Every Save reads the newest copy first and edits that (Logen
        // 2026-10-31), not the one read at launch: a hashtag followed in
        // another app since is kept. A key setup just made has no list
        // anywhere: nothing to wait for.
        if (FreshAccountKeys.isFresh(context, hex)) {
            confirmed = true
        } else {
            val pending = fetch ?: startFetch()
            // An account switch cancels the fetch; that is a "no", not our own cancellation.
            val ok = try {
                pending.await()
            } catch (e: CancellationException) {
                currentCoroutineContext().ensureActive()
                false
            }
            if (!ok || accountHex != hex) return@withContext revert(hex)
        }

        val next = applied(list)
        if (next == list) {
            _hashtags.value = list.hashtags
            return@withContext true
        }
        val event = try {
            // Locked to this account: a switch mid-sign refuses the result.
            val lock = nostrService.lockPostingAccount()
            if (lock.hex != hex) return@withContext revert(hex)
            nostrService.signEventAsync(
                kind = InterestList.KIND,
                content = next.content,
                tags = next.tags,
                lockedTo = lock,
                notBefore = list.createdAt + 1,
            )?.takeIf { it.pubkey == hex }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "kind 10015 not signed: ${e.message}")
            null
        }
        if (event == null || accountHex != hex) return@withContext revert(hex)
        accept(next.copy(createdAt = maxOf(event.createdAt, list.createdAt + 1)))
        nostrService.postEvent(event)
        true
    }

    // ── Private ───────────────────────────────────────────────────────

    /** Puts the button back to the list we have; false (nothing published). */
    private fun revert(hex: String): Boolean {
        if (accountHex == hex) _hashtags.value = list.hashtags
        return false
    }

    private fun switchAccount(hex: String) {
        fetch?.cancel()
        fetch = null
        accountHex = hex
        confirmed = false
        refusal = null
        list = loadCached(hex) ?: InterestList()
        _hashtags.value = list.hashtags
        if (hex.isNotEmpty()) startFetch()
    }

    private fun startFetch(): Deferred<Boolean> {
        val hex = accountHex
        val task = scope.async {
            val result = withContext(Dispatchers.IO) {
                // Only the account's own relays (its kind 10002) say the list is known (Logen 2026-11-01).
                val own = runCatching { nostrService.ownListRelays(hex) }
                    .onFailure { if (it is CancellationException) throw it }.getOrDefault(emptyList())
                val seen = HashSet<String>()
                fetchLatest(hex, (own + queryRelays(hex)).filter { seen.add(LookupSocketPool.relayKey(it)) }, own)
            }
            if (accountHex != hex) return@async false
            fetch = null
            refusal = result.unknownWhy
            if (result.unknownWhy != null) return@async false
            val remote = result.newest
            if (remote != null && remote.createdAt >= list.createdAt) accept(remote)
            confirmed = true
            true
        }
        fetch = task
        return task
    }

    private fun accept(newList: InterestList) {
        list = newList
        _hashtags.value = newList.hashtags
        saveCached(newList, accountHex)
    }

    /**
     * Where an account's lists live: its own outbox first, then the relays
     * this app reads and writes, including the local relay when it is up.
     */
    private fun queryRelays(hex: String): List<String> {
        val config = configStore.config.value
        val relayUp = RelayForegroundService.relayStatus.value == RelayForegroundService.RelayStatus.RUNNING
        val urls = buildList {
            addAll(nostrService.outboxRelays.value[hex].orEmpty())
            config.nostrURL?.takeIf { relayUp }?.let(::add)
            addAll(config.activeFeedRelays)
            addAll(config.activeBlastrRelays)
        }.ifEmpty { RelayConfiguration.FALLBACK_RELAYS }
        val seen = HashSet<String>()
        return urls.filter { it.isNotBlank() && seen.add(LookupSocketPool.relayKey(it)) }
    }

    /**
     * [newest] found, or null when none was. [unknownWhy] non-null: the list isn't known ([ListMerge.unknownWhy]) and
     * nothing may be signed over it.
     */
    private class FetchResult(val newest: InterestList?, val unknownWhy: String?)

    /**
     * The newest kind 10015 by [author], known only by the account's [own] relays ([ListMerge.unknownWhy]): an own
     * relay sent it or most of them answered, and for "none" every own relay and every relay asked answered (one
     * "none" is not "you have none"). A copy dated [ListMerge.MAX_SKEW] or more ahead is skipped.
     */
    private suspend fun fetchLatest(author: String, relays: List<String>, own: List<String>): FetchResult {
        if (own.isEmpty()) return FetchResult(null, ListMerge.NO_RELAY_LIST)
        if (relays.isEmpty()) return FetchResult(null, ListMerge.NOT_ANSWERED)
        val answered = AtomicInteger(0)
        val answeredBy = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
        val sentBy = java.util.concurrent.ConcurrentHashMap<String, Long>()
        val ahead = java.util.concurrent.atomic.AtomicBoolean(false)
        val lock = Any()
        var newest: InterestList? = null
        val filter = """{"kinds":[${InterestList.KIND}],"authors":["$author"],"limit":1}"""
        val subId = "interests-${UUID.randomUUID().toString().take(8)}"
        coroutineScope {
            relays.map { url ->
                async {
                    val outcome = try {
                        lookupPool.query(url, subId, listOf(filter), FETCH_TIMEOUT_MS) { msg ->
                            parseEvent(msg, author)?.let { found ->
                                if (!ListMerge.notAhead(found.createdAt)) { ahead.set(true); return@let }
                                sentBy.merge(url, found.createdAt, ::maxOf)
                                synchronized(lock) {
                                    if (found.createdAt > (newest?.createdAt ?: -1)) newest = found
                                }
                            }
                        }
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        LookupSocketPool.Outcome.FAILED
                    }
                    if (outcome == LookupSocketPool.Outcome.EOSE) { answered.incrementAndGet(); answeredBy.add(url) }
                }
            }.awaitAll()
        }
        val found = synchronized(lock) { newest }
        val from = sentBy.filterValues { found != null && it == found.createdAt }.keys
        val why = ListMerge.unknownWhy(own, answeredBy, from, found != null, ahead.get())
            ?: if (found == null && answered.get() < relays.size) ListMerge.NOT_ANSWERED else null
        return FetchResult(found, why)
    }

    /** A validly signed kind 10015 by [author] from an EVENT frame, else null. */
    private fun parseEvent(msg: String, author: String): InterestList? = try {
        val array = json.parseToJsonElement(msg) as? JsonArray
        val event = array?.takeIf { it.size >= 3 && it[0].jsonPrimitive.contentOrNull == "EVENT" }?.get(2) as? JsonObject
        val kind = event?.get("kind")?.jsonPrimitive?.intOrNull
        val pubkey = event?.get("pubkey")?.jsonPrimitive?.contentOrNull
        val createdAt = event?.get("created_at")?.jsonPrimitive?.longOrNull
        if (event == null || kind != InterestList.KIND || pubkey != author || createdAt == null) {
            null
        } else if (!HavenBridge.verifyEvent(event.toString())) {
            null
        } else {
            InterestList(
                tags = event["tags"]?.jsonArray?.map { t -> t.jsonArray.map { it.jsonPrimitive.contentOrNull.orEmpty() } }
                    .orEmpty(),
                content = event["content"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                createdAt = createdAt,
            )
        }
    } catch (e: Exception) {
        Log.w(TAG, "unusable relay message: ${e.message}")
        null
    }

    // ── Cache (iOS keeps the same JSON in UserDefaults as `interestList.<hex>`) ──

    private fun cacheKey(hex: String) = "interestList.$hex"

    private fun loadCached(hex: String): InterestList? {
        if (hex.isEmpty()) return null
        val raw = prefs.getString(cacheKey(hex), null) ?: return null
        return try {
            json.decodeFromString(InterestList.serializer(), raw)
        } catch (e: Exception) {
            null
        }
    }

    private fun saveCached(list: InterestList, hex: String) {
        if (hex.isEmpty()) return
        prefs.edit().putString(cacheKey(hex), json.encodeToString(InterestList.serializer(), list)).apply()
    }
}
