package com.nostrvault.service

import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.TopicFeedFilter
import android.util.Log
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray

/**
 * The topic feed's screening for an account with no web of trust yet (Fill
 * your feed), the stateful half of iOS `HashtagFeedModel`'s screening. Every
 * post from outside your follows lands in the pool; [onShown] gets the ones
 * [TopicFeedFilter] passes, posts people responded to first. Follow counts
 * come from each author's kind 3, responders from replies, reposts,
 * reactions and signed zaps on the shown posts.
 *
 * [query] is one REQ to the feed relays that returns when every relay has
 * answered or after a timeout, handing over each verified event as it
 * comes. Thread-safe: posts arrive off the main thread.
 */
class TopicFeedScreener(
    private val scope: CoroutineScope,
    private val query: suspend (filters: List<JsonObject>, onEvent: (JsonObject) -> Unit) -> Unit,
    /** Checks a zap request's signature, given its JSON. */
    private val isValid: (String) -> Boolean,
    private val onShown: (List<FeedNote>) -> Unit,
) {
    companion object {
        /** Posts arrive in a stream: ask about responders once a second, not once per post. */
        const val RESPONDER_BATCH_MS = 1_000L
        /** Per filter, because `limit` caps each one and one busy post must not use it up for the others. */
        const val RESPONDER_IDS_PER_FILTER = 25
        const val AUTHORS_PER_FILTER = 100
    }

    private val lock = Any()
    private var generation = 0
    /** Newest first. */
    private var pool: List<FeedNote> = emptyList()
    private val followCounts = HashMap<String, Int>()
    private val lookingUp = HashSet<String>()
    private val responders = HashMap<String, MutableSet<String>>()
    private val askedResponders = HashSet<String>()
    private val pendingResponders = ArrayList<String>()
    private var rescreenQueued = false
    private var respondersQueued = false
    private val jobs = ArrayList<Job>()
    private var lastShown: List<String> = emptyList()

    /** The oldest post asked for, where an older page carries on from. */
    fun oldest(): FeedNote? = synchronized(lock) { pool.lastOrNull() }

    /** A post from outside your follows. */
    fun add(note: FeedNote) {
        synchronized(lock) {
            val index = pool.indexOfFirst { it.createdAt < note.createdAt }.let { if (it < 0) pool.size else it }
            // Not capped, as on iOS: ~95% of it is screened out, and a cap
            // trimmed older pages straight back off, ending paging early.
            pool = pool.toMutableList().apply { add(index, note) }
        }
        queueRescreen()
    }

    /** A new feed: forget the posts, keep what's known about authors. */
    fun reset() {
        stop()
        synchronized(lock) {
            pool = emptyList()
            lastShown = emptyList()
        }
    }

    /** Lookups in flight are dropped; what they hadn't answered is asked again on [resume]. */
    fun stop() {
        synchronized(lock) {
            generation += 1
            jobs.forEach { it.cancel() }
            jobs.clear()
            lookingUp.clear()
            askedResponders.removeAll { it !in responders }
            pendingResponders.clear()
            rescreenQueued = false
            respondersQueued = false
        }
    }

    /** The same feed reopened: ask again for what's on hand. */
    fun resume() = queueRescreen()

    /** One pass however many posts arrived together. */
    private fun queueRescreen() {
        val gen = synchronized(lock) {
            if (rescreenQueued) return
            rescreenQueued = true
            generation
        }
        launch(gen) {
            synchronized(lock) { rescreenQueued = false }
            lookUpFollowCounts(gen)
            rescreen()
        }
    }

    private fun rescreen() {
        val (next, fresh) = synchronized(lock) {
            val posts = pool.map { TopicFeedFilter.Post(it.id, it.pubkey, it.content, it.tags) }
            val shownIds = TopicFeedFilter.shown(posts, followCounts)
            val fresh = shownIds.filter { askedResponders.add(it) }
            val byId = pool.associateBy { it.id }
            val counts = responders.mapValues { it.value.size }
            val next = TopicFeedFilter.ordered(shownIds, counts).mapNotNull { byId[it] }
            val changed = next.map { it.id } != lastShown
            lastShown = next.map { it.id }
            (if (changed) next else null) to fresh
        }
        if (next != null) onShown(next)
        if (fresh.isNotEmpty()) lookUpResponders(fresh)
    }

    private fun lookUpResponders(ids: List<String>) {
        val gen = synchronized(lock) {
            pendingResponders += ids
            if (respondersQueued) return
            respondersQueued = true
            generation
        }
        launch(gen) {
            delay(RESPONDER_BATCH_MS)
            val missing = synchronized(lock) {
                respondersQueued = false
                pendingResponders.toList().also { pendingResponders.clear() }
            }
            if (missing.isNotEmpty()) askResponders(missing, gen)
        }
    }

    private suspend fun askResponders(missing: List<String>, gen: Int) {
        val authors = synchronized(lock) { pool.associate { it.id to it.pubkey } }
        val wanted = missing.toSet()
        val found = HashMap<String, MutableSet<String>>()
        val filters = missing.chunked(RESPONDER_IDS_PER_FILTER).map { ids ->
            buildJsonObject {
                putJsonArray("kinds") { listOf(1, 6, 7, 9735).forEach { add(JsonPrimitive(it)) } }
                putJsonArray("#e") { ids.forEach { add(JsonPrimitive(it)) } }
                put("limit", 1000)
            }
        }
        query(filters) { event ->
            val pubkey = TopicFeedFilter.responder(event, isValid) ?: return@query
            for (tag in TopicFeedFilter.tagsOf(event)) {
                if (tag.size < 2 || tag[0] != "e" || tag[1] !in wanted) continue
                if (authors[tag[1]] != pubkey) synchronized(found) { found.getOrPut(tag[1]) { HashSet() }.add(pubkey) }
            }
        }
        synchronized(lock) {
            if (gen != generation) return
            for (id in missing) responders.getOrPut(id) { HashSet() }.addAll(found[id].orEmpty())
        }
        rescreen()
    }

    /** Each new author's newest kind 3, counted. Authors no relay has a
     *  follow list for count as 0, which keeps them out: people follow. */
    private suspend fun lookUpFollowCounts(gen: Int) {
        val missing = synchronized(lock) {
            pool.map { it.pubkey }.toSet().filter { it !in followCounts && it !in lookingUp }
                .also { lookingUp.addAll(it) }
        }
        if (missing.isEmpty()) return
        val wanted = missing.toSet()
        val newest = HashMap<String, Pair<Long, Int>>()
        val filters = missing.chunked(AUTHORS_PER_FILTER).map { authors ->
            buildJsonObject {
                putJsonArray("kinds") { add(JsonPrimitive(3)) }
                putJsonArray("authors") { authors.forEach { add(JsonPrimitive(it)) } }
            }
        }
        launch(gen) {
            query(filters) { event ->
                val pubkey = (event["pubkey"] as? JsonPrimitive)?.contentOrNull ?: return@query
                val createdAt = (event["created_at"] as? JsonPrimitive)?.longOrNull ?: return@query
                if (pubkey !in wanted || (event["kind"] as? JsonPrimitive)?.contentOrNull != "3") return@query
                val follows = TopicFeedFilter.tagsOf(event).count { it.firstOrNull() == "p" }
                synchronized(newest) {
                    if ((newest[pubkey]?.first ?: 0L) < createdAt) newest[pubkey] = createdAt to follows
                }
            }
            synchronized(lock) {
                if (gen != generation) return@launch
                for (author in missing) if (author !in followCounts) followCounts[author] = newest[author]?.second ?: 0
                lookingUp.removeAll(wanted)
            }
            rescreen()
        }
    }

    /** Runs [block] unless the feed has moved on; [stop] cancels it. A
     *  lookup that fails (a relay's odd frame) only loses that lookup. */
    private fun launch(gen: Int, block: suspend () -> Unit) {
        val job = scope.launch {
            if (synchronized(lock) { gen != generation }) return@launch
            try {
                block()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w("TopicFeedScreener", "lookup failed: ${e.message}")
            }
        }
        synchronized(lock) {
            if (gen != generation) job.cancel() else jobs += job
            jobs.removeAll { it.isCompleted }
        }
    }
}
