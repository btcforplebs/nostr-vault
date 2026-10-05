package com.nostrvault.widget

import android.content.Context
import android.graphics.Bitmap
import androidx.compose.runtime.Composable
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalSize
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.util.concurrent.TimeUnit

/**
 * Home-screen widgets, drawn from the snapshot the app keeps on disk
 * ([WidgetSnapshotStore]).
 *
 * Glance runs in the app's own process, so a widget can read that file
 * directly — there is no extension boundary and no serialisation budget the
 * way iOS has. What a widget still cannot do is fetch: it draws once, from
 * whatever the last publish left behind.
 */

// ── Vault Pulse ────────────────────────────────────────────────────────

/**
 * Relay status. This widget exists on Android and not on iOS, and the reason
 * is a real platform difference rather than an oversight: iOS cannot keep the
 * relay running in the background, so "your vault is live" was a promise it
 * could not keep and the widget was cut. RelayForegroundService keeps it true
 * here.
 */
class VaultPulseWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val snapshot = WidgetSnapshotStore.read(context)
        provideContent { GlanceTheme { PulseContent(context, snapshot) } }
    }
}

class VaultPulseReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = VaultPulseWidget()
}

@Composable
private fun PulseContent(context: Context, snapshot: VaultSnapshot) {
    Column(
        modifier = GlanceModifier
            .fillMaxSize()
            .background(WidgetTheme.Background)
            .padding(12.dp)
            .clickable(openApp(context, "relay")),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(if (snapshot.relay.running) "Vault live" else "Vault down", style = WidgetTheme.Title)
        }
        Spacer(GlanceModifier.height(6.dp))
        Text("${snapshot.relay.eventsStored}", style = WidgetTheme.Value)
        Text("events stored", style = WidgetTheme.Caption)
        Spacer(GlanceModifier.height(6.dp))
        Text(
            "${snapshot.relay.connections} connected · ${freshness(snapshot.updatedAt)}",
            style = WidgetTheme.Caption,
        )
    }
}

// ── Quick actions ──────────────────────────────────────────────────────

class QuickActionsWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        provideContent { GlanceTheme { QuickActionsContent(context) } }
    }
}

class QuickActionsReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = QuickActionsWidget()
}

@Composable
private fun QuickActionsContent(context: Context) {
    Row(
        modifier = GlanceModifier
            .fillMaxSize()
            .background(WidgetTheme.Background)
            .padding(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        listOf(
            "Post" to "compose",
            "Search" to "search",
            "DMs" to "dms",
            "Media" to "media",
        ).forEach { (label, destination) ->
            Column(
                modifier = GlanceModifier
                    .defaultWeight()
                    .clickable(openApp(context, destination)),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(label, style = WidgetTheme.Title)
            }
        }
    }
}

// ── Feed ───────────────────────────────────────────────────────────────

class FeedWidget : GlanceAppWidget() {
    // Exact: the row count is worked out from the real height (FeedLayout).
    override val sizeMode: SizeMode = SizeMode.Exact

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val snapshot = WidgetSnapshotStore.read(context)
        val avatars = loadAvatars(context, snapshot.feed + snapshot.mentions)
        provideContent { GlanceTheme { FeedContent(context, snapshot, avatars) } }
    }

    /**
     * Avatars have to exist before the composition runs — it draws once and
     * cannot wait on a download. Keyed by picture URL, so two notes from one
     * author cost one fetch; both lists are loaded so switching the source is
     * a recompose, not a refetch. Every author gets a bitmap: the picture cut
     * to a circle, or a circle tinted to their pubkey.
     */
    private suspend fun loadAvatars(
        context: Context,
        notes: List<VaultSnapshot.SnapshotNote>,
    ): Map<String, Bitmap> {
        val urls = notes.mapNotNull { it.authorPicture }.distinct().take(AVATAR_FETCH_LIMIT)
        val pictures = WidgetImages.load(
            context,
            urls.map { WidgetImages.Source(id = it, url = it) },
            maxPixel = AVATAR_PIXELS * 2,
            remoteLimit = AVATAR_FETCH_LIMIT,
        )
        val out = mutableMapOf<String, Bitmap>()
        for (note in notes) {
            if (note.author in out) continue
            val picture = note.authorPicture?.let { pictures[it] }
            out[note.author] = picture?.let { WidgetImages.square(it, AVATAR_PIXELS, circle = true) }
                ?: WidgetImages.fallback(note.author, AVATAR_PIXELS, circle = true, strong = 0.9f, weak = 0.45f)
        }
        return out
    }

    companion object {
        private const val AVATAR_PIXELS = 64
        private const val AVATAR_FETCH_LIMIT = 16
    }
}

class FeedReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = FeedWidget()
}

/**
 * One text size for the whole widget — author, age, body, header. Mixing sizes
 * in a box this small reads as clutter; weight and colour carry the hierarchy
 * (iOS FeedGlanceView.textSize).
 */
private val FEED_TEXT = 12.sp
private const val FEED_LINE_DP = 15f
private const val FEED_HEADER_DP = 26f
private val FEED_PAD = 12.dp

@Composable
private fun FeedContent(
    context: Context,
    snapshot: VaultSnapshot,
    avatars: Map<String, Bitmap>,
    mentions: Boolean = false,
    bodyLines: Int = 2,
    showAvatars: Boolean = true,
) {
    val notes = if (mentions) snapshot.mentions else snapshot.feed
    val size = LocalSize.current
    Column(
        modifier = GlanceModifier
            .fillMaxSize()
            .background(WidgetTheme.Background)
            .padding(FEED_PAD)
            .clickable(openApp(context, if (mentions) "mentions" else "feed")),
    ) {
        Row(modifier = GlanceModifier.fillMaxWidth().height(18.dp)) {
            Text(if (mentions) "Mentions" else "Following", style = WidgetTheme.Title)
            Spacer(GlanceModifier.defaultWeight())
            Text(freshness(snapshot.updatedAt), style = WidgetTheme.Caption)
        }
        Spacer(GlanceModifier.height(8.dp))
        when {
            snapshot.updatedAt <= 0L -> {
                Text("Open Nostr Vault to load your feed", style = WidgetTheme.Caption)
                return@Column
            }
            notes.isEmpty() -> {
                Text(if (mentions) "No recent mentions" else "No recent notes", style = WidgetTheme.Caption)
                return@Column
            }
        }
        val plan = FeedLayout.plan(
            availableHeight = size.height.value - FEED_PAD.value * 2,
            headerHeight = FEED_HEADER_DP,
            rowHeight = FEED_LINE_DP * (1 + bodyLines),
            minSpacing = 6f,
            maxSpacing = 18f,
            noteCount = notes.size,
        )
        val now = System.currentTimeMillis()
        notes.take(plan.rows).forEachIndexed { index, note ->
            if (index > 0) Spacer(GlanceModifier.height(plan.spacing.dp))
            NoteRow(context, note, avatars[note.author].takeIf { showAvatars }, bodyLines, now)
        }
    }
}

@Composable
private fun NoteRow(
    context: Context,
    note: VaultSnapshot.SnapshotNote,
    avatar: Bitmap?,
    bodyLines: Int,
    now: Long,
) {
    Row(
        modifier = GlanceModifier
            .fillMaxWidth()
            .clickable(openApp(context, "note/${note.id}")),
        verticalAlignment = Alignment.Top,
    ) {
        if (avatar != null) {
            Image(
                provider = ImageProvider(avatar),
                contentDescription = null,
                modifier = GlanceModifier.size(20.dp),
            )
            Spacer(GlanceModifier.width(7.dp))
        }
        Column(modifier = GlanceModifier.defaultWeight()) {
            Row {
                Text(
                    note.displayName,
                    maxLines = 1,
                    style = TextStyle(
                        color = ColorProvider(WidgetTheme.Primary),
                        fontSize = FEED_TEXT,
                        fontWeight = FontWeight.Medium,
                    ),
                )
                Spacer(GlanceModifier.width(4.dp))
                Text(
                    shortAge(note.createdAt, now),
                    maxLines = 1,
                    style = TextStyle(color = ColorProvider(WidgetTheme.Secondary), fontSize = FEED_TEXT),
                )
            }
            Text(
                note.text,
                maxLines = bodyLines,
                style = TextStyle(color = ColorProvider(WidgetTheme.Primary.copy(alpha = 0.82f)), fontSize = FEED_TEXT),
            )
        }
    }
}

// ── Shared ─────────────────────────────────────────────────────────────

/**
 * How old the snapshot is. A widget cannot fetch, so saying when the numbers
 * were true is the difference between stale data and a lie.
 */
private fun freshness(updatedAt: Long): String {
    if (updatedAt <= 0L) return "no data yet"
    val minutes = TimeUnit.MILLISECONDS.toMinutes(System.currentTimeMillis() - updatedAt)
    return when {
        minutes < 1 -> "just now"
        minutes < 60 -> "${minutes}m ago"
        minutes < 60 * 24 -> "${minutes / 60}h ago"
        else -> "${minutes / (60 * 24)}d ago"
    }
}
