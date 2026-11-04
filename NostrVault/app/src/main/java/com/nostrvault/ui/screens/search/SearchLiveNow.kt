package com.nostrvault.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.LiveStream
import com.nostrvault.service.FeedService
import com.nostrvault.service.LiveFeedService
import com.nostrvault.service.NostrService
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.components.LiveStreamRouter
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.widget.LiveNowRules
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import javax.inject.Inject

/**
 * Live now at the top of Search (Logen, 2026-11-04; iOS SearchLiveNowSection):
 * people you follow who are on air, with picture, name and stream title; a tap
 * opens the player. Same ask and rules as the Live now widget
 * ([LiveFeedService.liveRequests], [LiveNowRules.pick]). Asks only while
 * Search's start page is on screen, every [LiveNowRules.REFRESH_MS]; nothing
 * is saved or published.
 */
@HiltViewModel
class SearchLiveNowViewModel @Inject constructor(
    private val nostrService: NostrService,
    private val configStore: ConfigStore,
    private val feedService: FeedService,
) : ViewModel() {
    private val _streams = MutableStateFlow<List<LiveStream>>(emptyList())
    val streams: StateFlow<List<LiveStream>> = _streams.asStateFlow()

    private var loop: Job? = null
    private val json = Json { ignoreUnknownKeys = true }

    /** Search's start page is showing: ask now and keep asking. */
    fun start() {
        if (loop?.isActive == true) return
        loop = viewModelScope.launch {
            while (isActive) {
                refresh()
                delay(LiveNowRules.REFRESH_MS)
            }
        }
    }

    fun stop() {
        loop?.cancel()
        loop = null
    }

    private suspend fun refresh() {
        // The follow list can arrive after Search did: wait for it a little.
        var follows = feedService.followedPubkeySet()
        var waited = 0
        while (follows.isEmpty() && waited < 15) { delay(1_000); waited++; follows = feedService.followedPubkeySet() }
        if (follows.isEmpty()) { _streams.value = emptyList(); return }
        val config = configStore.config.value
        val relays = config.activeFeedRelays
        if (relays.isEmpty()) return
        val blocked = config.blockedForActiveAccount().mapNotNull { nostrService.npubToHex(it) }.toSet()
        val filters = LiveFeedService.liveRequests("s", follows).flatMap { (_, req) ->
            (json.parseToJsonElement(req) as JsonArray).drop(2).map { it.toString() }
        }
        var answered = false
        val events = nostrService.queryRawEvents(filters, relays, timeoutMs = 12_000L, onAnswered = { answered = true })
        // Nobody answered: keep what is showing rather than blank it.
        if (!answered && events.isEmpty()) return
        val streams = events.mapNotNull(::streamOf)
        val picked = LiveNowRules.pick(streams, follows, blocked, System.currentTimeMillis() / 1000)
        nostrService.fetchMissingProfiles(picked.map { it.hostPubkey })
        _streams.value = picked
    }

    private fun streamOf(event: JsonObject): LiveStream? {
        if ((event["kind"] as? JsonPrimitive)?.intOrNull != LiveStream.KIND) return null
        val pubkey = (event["pubkey"] as? JsonPrimitive)?.contentOrNull ?: return null
        val createdAt = (event["created_at"] as? JsonPrimitive)?.longOrNull ?: return null
        val tags = (event["tags"] as? JsonArray).orEmpty().mapNotNull { tag ->
            (tag as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
        }
        return LiveStream.from(pubkey, createdAt, tags)
    }

    override fun onCleared() {
        stop()
        super.onCleared()
    }
}

/** Rows drawn; the rest are a "+N more live" line (iOS LiveNow.maxRows). */
private const val SEARCH_LIVE_ROWS = 5

/** Starts the ask while it is composed and stops it when it leaves. */
@Composable
fun SearchLiveNowEffect(viewModel: SearchLiveNowViewModel) {
    DisposableEffect(viewModel) {
        viewModel.start()
        onDispose { viewModel.stop() }
    }
}

/** The section itself. Draws nothing when nobody is live. */
@Composable
fun SearchLiveNowSection(
    streams: List<LiveStream>,
    profiles: Map<String, com.nostrvault.data.model.FeedProfile>,
) {
    if (streams.isEmpty()) return
    Column(modifier = Modifier.fillMaxWidth().padding(bottom = 24.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(7.dp).background(Color.Red, CircleShape))
            Spacer(Modifier.width(6.dp))
            Text("Live now", color = SecondaryText, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
        }
        Spacer(Modifier.height(10.dp))
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(SecondaryText.copy(alpha = 0.08f), RoundedCornerShape(12.dp)),
        ) {
            streams.take(SEARCH_LIVE_ROWS).forEachIndexed { index, stream ->
                if (index > 0) HorizontalDivider(modifier = Modifier.padding(start = 56.dp), color = SecondaryText.copy(alpha = 0.15f))
                LiveRow(stream, profiles[stream.hostPubkey])
            }
        }
        if (streams.size > SEARCH_LIVE_ROWS) {
            Spacer(Modifier.height(8.dp))
            Text("+${streams.size - SEARCH_LIVE_ROWS} more live", color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

@Composable
private fun LiveRow(stream: LiveStream, profile: com.nostrvault.data.model.FeedProfile?) {
    val name = profile?.bestName ?: stream.hostPubkey.take(8)
    val title = stream.title ?: stream.summary ?: "Live now"
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable { LiveStreamRouter.open(stream) }
            .padding(horizontal = 12.dp, vertical = 8.dp)
            .semantics { contentDescription = "$name is live: $title. Opens the stream" },
    ) {
        AvatarImage(url = profile?.pictureURL, pubkey = stream.hostPubkey, size = 34.dp, displayName = name)
        Spacer(Modifier.width(10.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(name, color = PrimaryText, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(title, color = SecondaryText, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Spacer(Modifier.width(4.dp))
        Text(
            "LIVE",
            color = Color.White,
            fontSize = 10.sp,
            fontWeight = FontWeight.Black,
            modifier = Modifier
                .background(Color.Red, RoundedCornerShape(50))
                .padding(horizontal = 6.dp, vertical = 2.dp),
        )
    }
}
