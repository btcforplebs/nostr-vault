package com.nostrvault.widget

import android.content.Context
import android.graphics.Bitmap
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.stringPreferencesKey
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
import androidx.glance.appwidget.cornerRadius
import androidx.glance.currentState
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
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
    override val sizeMode: SizeMode = SizeMode.Exact

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val snapshot = WidgetSnapshotStore.read(context)
        provideContent {
            GlanceTheme {
                val config = QuickActionsConfig.from(currentState<Preferences>().asLookup())
                QuickActionsContent(context, config, snapshot.unreadDMs)
            }
        }
    }
}

class QuickActionsReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = QuickActionsWidget()
}

/**
 * The chosen tiles (iOS QuickActionsView). A narrow widget shows the first
 * two — four crammed into a 2-cell slot leaves tap targets too small to hit;
 * a tall one lays four out two by two.
 */
@Composable
private fun QuickActionsContent(context: Context, config: QuickActionsConfig, unreadDMs: Int) {
    val size = LocalSize.current
    val actions = if (size.width < 200.dp) config.slots.take(2) else config.slots
    val rows = if (size.height >= 110.dp && actions.size > 2) actions.chunked(2) else listOf(actions)
    Column(
        modifier = GlanceModifier
            .fillMaxSize()
            .background(WidgetTheme.Background)
            .padding(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        rows.forEachIndexed { r, row ->
            if (r > 0) Spacer(GlanceModifier.height(8.dp))
            Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                row.forEachIndexed { i, action ->
                    if (i > 0) Spacer(GlanceModifier.width(8.dp))
                    ActionTile(
                        context,
                        action,
                        badge = unreadDMs.takeIf { action == QuickAction.DMS && it > 0 },
                        modifier = GlanceModifier.defaultWeight(),
                    )
                }
            }
        }
    }
}

@Composable
private fun ActionTile(context: Context, action: QuickAction, badge: Int?, modifier: GlanceModifier) {
    val tint = Color(action.tint)
    Row(
        modifier = modifier
            .background(Color.White.copy(alpha = 0.06f))
            .cornerRadius(13.dp)
            .padding(horizontal = 9.dp, vertical = 8.dp)
            .clickable(openApp(context, action.destination)),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // The tint swatch stands in for iOS's SF Symbol: it is what tells the
        // tiles apart at a glance.
        Box(
            modifier = GlanceModifier
                .size(10.dp)
                .background(tint)
                .cornerRadius(5.dp),
        ) {}
        Spacer(GlanceModifier.width(7.dp))
        Text(
            action.label,
            maxLines = 1,
            style = TextStyle(
                color = ColorProvider(WidgetTheme.Primary),
                fontSize = 12.sp,
                fontWeight = FontWeight.Medium,
            ),
        )
        if (badge != null) {
            Spacer(GlanceModifier.width(5.dp))
            Text(
                if (badge > 99) "99+" else "$badge",
                maxLines = 1,
                style = TextStyle(
                    color = ColorProvider(Color.White),
                    fontSize = 9.sp,
                    fontWeight = FontWeight.Bold,
                ),
                modifier = GlanceModifier
                    .background(Color(0xFFFF3B30))
                    .cornerRadius(7.dp)
                    .padding(horizontal = 4.dp, vertical = 1.dp),
            )
        }
    }
}

/** Glance state as the string lookup WidgetConfig parses. */
internal fun Preferences.asLookup(): (String) -> String? = { key -> this[stringPreferencesKey(key)] }

// ── Feed ───────────────────────────────────────────────────────────────

class FeedWidget : GlanceAppWidget() {
    // Exact: the row count is worked out from the real height (FeedLayout).
    override val sizeMode: SizeMode = SizeMode.Exact

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val snapshot = WidgetSnapshotStore.read(context)
        val avatars = loadAvatars(context, snapshot.feed + snapshot.mentions)
        provideContent {
            GlanceTheme {
                val config = FeedConfig.from(currentState<Preferences>().asLookup())
                FeedContent(
                    context,
                    snapshot,
                    avatars,
                    mentions = config.source == FeedSource.MENTIONS,
                    bodyLines = config.density.bodyLines,
                    showAvatars = config.showAvatars,
                )
            }
        }
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
    mentions: Boolean,
    bodyLines: Int,
    showAvatars: Boolean,
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
