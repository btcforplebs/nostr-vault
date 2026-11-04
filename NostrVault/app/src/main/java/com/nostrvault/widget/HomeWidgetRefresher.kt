package com.nostrvault.widget

import android.content.Context
import android.util.Log
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetManager
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.LiveStream
import com.nostrvault.service.FeedService
import com.nostrvault.service.LiveFeedService
import com.nostrvault.service.NostrService
import com.nostrvault.service.ZapsToday
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.intOrNull
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Fetches what the Live now and On this day widgets draw and writes it into
 * the widget snapshot.
 *
 * Two callers: the app while it is open ([runWhileOpen], every two minutes
 * for Live now), and a widget's own periodic update when its half of the
 * snapshot is stale ([refreshFromWidget]). Only widgets that are on the home
 * screen are fetched for, so an install without them asks no relay anything.
 *
 * Nothing here signs or publishes: Live now asks the feed relays for kind
 * 30311, On this day asks your own vault for your own kind 1 notes.
 */
@Singleton
class HomeWidgetRefresher @Inject constructor(
    @ApplicationContext private val context: Context,
    private val configStore: ConfigStore,
    private val nostrService: NostrService,
    private val feedService: FeedService,
) {
    private val liveLock = Mutex()
    private val dayLock = Mutex()
    private val json = Json { ignoreUnknownKeys = true }

    /**
     * While the app is in front: Live now every two minutes, On this day
     * whenever what is on file was picked for another day or account. An
     * account switch starts over at once, so neither widget keeps showing
     * the previous account's list; so does the follow list arriving, which
     * at launch lands after the first pass. A pass that got no answer (the
     * vault still starting, no network) is tried again after [RETRY_MS].
     */
    suspend fun runWhileOpen() {
        combine(configStore.activeAccountHexPubkey, feedService.followListIsKnown) { me, known -> me to known }
            .distinctUntilChanged()
            .collectLatest { (me, _) ->
                if (me.isEmpty()) return@collectLatest
                while (true) {
                    val snapshot = WidgetSnapshotStore.read(context)
                    val today = ZapsToday.startOfDay(System.currentTimeMillis())
                    var answered = true
                    if (installed(OnThisDayWidget::class.java) &&
                        (snapshot.onThisDay.account != me || snapshot.onThisDay.dayStart != today)
                    ) {
                        answered = refreshOnThisDay()
                    }
                    if (installed(LiveNowWidget::class.java)) answered = refreshLive() && answered
                    delay(if (answered) LiveNowRules.REFRESH_MS else RETRY_MS)
                }
            }
    }

    @Volatile private var lastLiveTry = 0L
    @Volatile private var lastDayTry = 0L

    /**
     * A widget found its half stale: ask once, then it redraws from the file.
     * At most once per [LiveNowRules.STALE_MS] per half: a relay that does not
     * answer leaves the half stale, and every redraw would otherwise wait on
     * it again.
     */
    suspend fun refreshFromWidget(live: Boolean) {
        val now = System.currentTimeMillis()
        if (live) {
            if (now - lastLiveTry < LiveNowRules.STALE_MS) return
            lastLiveTry = now
            refreshLive()
        } else {
            if (now - lastDayTry < LiveNowRules.STALE_MS) return
            lastDayTry = now
            refreshOnThisDay()
        }
    }

    private suspend fun installed(widget: Class<out GlanceAppWidget>): Boolean =
        runCatching { GlanceAppWidgetManager(context).getGlanceIds(widget).isNotEmpty() }.getOrDefault(false)

    // ── Live now ───────────────────────────────────────────────────────

    /** @return false when nothing answered, so the file was left as it was. */
    suspend fun refreshLive(): Boolean = liveLock.withLock {
        val me = configStore.activeAccountHexPubkey.value
        // A process the launcher started for the widget has no config loaded:
        // draw what is on file rather than guess an account.
        if (me.isEmpty()) return@withLock false
        val config = configStore.config.value
        val follows = feedService.followedPubkeySet().ifEmpty { ownFollows(me) }
        if (follows.isEmpty()) {
            // "Follow people" only once the list is known to be empty: at
            // launch it is empty for a moment because it has not loaded yet.
            if (!feedService.followListIsKnown.value) return@withLock false
            write { it.copy(live = VaultSnapshot.LiveNow(me, System.currentTimeMillis(), followsSomeone = false)) }
            return@withLock true
        }
        val relays = config.activeFeedRelays
        if (relays.isEmpty()) return@withLock false
        val blocked = config.blockedForActiveAccount().mapNotNull { nostrService.npubToHex(it) }.toSet()

        var answered = false
        val filters = LiveFeedService.liveRequests("w", follows).map { (_, req) -> filtersOf(req) }.flatten()
        val events = nostrService.queryRawEvents(filters, relays, timeoutMs = LIVE_TIMEOUT_MS, onAnswered = { answered = true })
        Log.d(TAG, "live now: ${events.size} events from ${relays.size} relays, answered=$answered")
        if (!answered && events.isEmpty()) return@withLock false
        // Each stream with the tags it came from, so a tap can rebuild it.
        val parsed = events.mapNotNull(::streamOf)
        val tagsByStream = parsed.associate { (s, tags) -> (s.address to s.createdAt) to tags }
        val streams = parsed.map { it.first }
        val now = System.currentTimeMillis()
        val picked = LiveNowRules.pick(streams, follows, blocked, now / 1000).take(LiveNowRules.MAX_ROWS)
        val profiles = profilesFor(picked.map { it.hostPubkey }, relays)
        val items = picked.map { s ->
            val p = profiles[s.hostPubkey]
            VaultSnapshot.LiveItem(
                address = s.address,
                host = s.hostPubkey,
                hostName = p?.first ?: (s.hostPubkey.take(8) + "…"),
                hostPicture = p?.second,
                title = s.title ?: s.summary ?: "Live",
                author = s.authorPubkey,
                createdAt = s.createdAt,
                tags = tagsByStream[s.address to s.createdAt].orEmpty(),
            )
        }
        write { it.copy(live = VaultSnapshot.LiveNow(me, now, followsSomeone = true, streams = items)) }
        true
    }

    private fun streamOf(event: JsonObject): Pair<LiveStream, List<List<String>>>? {
        if ((event["kind"] as? JsonPrimitive)?.intOrNull != LiveStream.KIND) return null
        val pubkey = (event["pubkey"] as? JsonPrimitive)?.contentOrNull ?: return null
        val createdAt = (event["created_at"] as? JsonPrimitive)?.longOrNull ?: return null
        val tags = tagsOf(event)
        return LiveStream.from(pubkey, createdAt, tags)?.let { it to tags }
    }

    /** The REQ's filter objects, as the strings queryRawEvents takes. */
    private fun filtersOf(req: String): List<String> =
        (json.parseToJsonElement(req) as JsonArray).drop(2).map { it.toString() }

    /** Your follows from your own vault's kind 3, for a process with no feed loaded. */
    private suspend fun ownFollows(me: String): Set<String> {
        val vault = configStore.config.value.nostrURL ?: return emptySet()
        val events = nostrService.queryRawEvents(listOf("""{"kinds":[3],"authors":["$me"],"limit":1}"""), listOf(vault))
        val newest = events.maxByOrNull { (it["created_at"] as? JsonPrimitive)?.longOrNull ?: 0L } ?: return emptySet()
        return tagsOf(newest).filter { it.size >= 2 && it[0] == "p" && it[1].length == 64 }.map { it[1] }.toSet()
    }

    /** Name and picture per host: the app's profile cache first, then a kind 0 lookup for the rest. */
    private suspend fun profilesFor(hosts: List<String>, relays: List<String>): Map<String, Pair<String, String?>> {
        val out = mutableMapOf<String, Pair<String, String?>>()
        val cached = nostrService.profiles.value
        for (h in hosts) cached[h]?.let { out[h] = it.bestName to it.pictureURL?.takeIf(String::isNotBlank) }
        val missing = hosts.filter { it !in out }.distinct()
        if (missing.isEmpty()) return out
        val authors = missing.joinToString(",") { "\"$it\"" }
        val events = nostrService.queryRawEvents(
            listOf("""{"kinds":[0],"authors":[$authors]}"""),
            (relays + PROFILE_RELAYS).distinct(),
        )
        events.groupBy { (it["pubkey"] as? JsonPrimitive)?.contentOrNull }
            .forEach { (pubkey, list) ->
                if (pubkey == null || pubkey !in missing) return@forEach
                val newest = list.maxByOrNull { (it["created_at"] as? JsonPrimitive)?.longOrNull ?: 0L } ?: return@forEach
                val meta = runCatching {
                    json.parseToJsonElement((newest["content"] as JsonPrimitive).content).jsonObject
                }.getOrNull() ?: return@forEach
                fun field(k: String) = (meta[k] as? JsonPrimitive)?.contentOrNull?.trim()?.takeIf { it.isNotEmpty() }
                val name = field("display_name") ?: field("name") ?: return@forEach
                out[pubkey] = name to field("picture")
            }
        return out
    }

    // ── On this day ────────────────────────────────────────────────────

    /** @return false when the vault did not answer, so the file was left as it was. */
    suspend fun refreshOnThisDay(): Boolean = dayLock.withLock {
        val me = configStore.activeAccountHexPubkey.value
        if (me.isEmpty()) return@withLock false
        // Your own vault only, never an outside relay: these are your notes.
        val vault = configStore.config.value.nostrURL ?: return@withLock false
        val now = System.currentTimeMillis()
        val windows = OnThisDayRules.windows(now)
        var answered = false
        val events = nostrService.queryRawEvents(
            windows.map { OnThisDayRules.filter(me, it) },
            listOf(vault),
            timeoutMs = DAY_TIMEOUT_MS,
            onAnswered = { answered = true },
        )
        Log.d(TAG, "on this day: ${events.size} notes from $vault, answered=$answered")
        if (!answered && events.isEmpty()) return@withLock false
        val notes = events.mapNotNull(::noteOf)
        val picked = windows.flatMap { w ->
            OnThisDayRules.notes(notes, me, w).map { n ->
                VaultSnapshot.DayNote(
                    id = n.id,
                    yearsAgo = w.years,
                    text = OnThisDayRules.lineText(n.content).take(200),
                    createdAt = n.createdAt,
                )
            }
        }
        write { it.copy(onThisDay = VaultSnapshot.OnThisDay(me, ZapsToday.startOfDay(now), picked)) }
        true
    }

    private fun noteOf(event: JsonObject): OnThisDayRules.Note? {
        fun str(k: String) = (event[k] as? JsonPrimitive)?.contentOrNull
        return OnThisDayRules.Note(
            id = str("id") ?: return null,
            pubkey = str("pubkey") ?: return null,
            kind = (event["kind"] as? JsonPrimitive)?.intOrNull ?: return null,
            createdAt = (event["created_at"] as? JsonPrimitive)?.longOrNull ?: return null,
            content = str("content").orEmpty(),
            tags = tagsOf(event),
        )
    }

    // ── Shared ─────────────────────────────────────────────────────────

    private fun tagsOf(event: JsonObject): List<List<String>> =
        (event["tags"] as? JsonArray).orEmpty().mapNotNull { tag ->
            (tag as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
        }

    private suspend fun write(transform: (VaultSnapshot) -> VaultSnapshot) {
        val changed = WidgetSnapshotStore.update(context, transform)
        if (changed) WidgetPublisher.redraw(context)
    }

    companion object {
        private const val TAG = "HomeWidgetRefresher"
        private const val LIVE_TIMEOUT_MS = 12_000L
        private const val DAY_TIMEOUT_MS = 6_000L
        /** After a pass nothing answered: soon, but not a tight loop. */
        private const val RETRY_MS = 20_000L

        /** Profile indexers, for hosts the app has never drawn. */
        private val PROFILE_RELAYS = listOf("wss://purplepag.es", "wss://user.kindpag.es")

        /** For the widgets' providers, which have no Hilt graph of their own. */
        fun from(context: Context): HomeWidgetRefresher =
            EntryPointAccessors.fromApplication(context.applicationContext, Access::class.java).homeWidgetRefresher()

        internal fun logFailure(e: Throwable) = Log.w(TAG, "refresh failed: ${e.message}")
    }

    @EntryPoint
    @InstallIn(SingletonComponent::class)
    interface Access {
        fun homeWidgetRefresher(): HomeWidgetRefresher
    }
}
