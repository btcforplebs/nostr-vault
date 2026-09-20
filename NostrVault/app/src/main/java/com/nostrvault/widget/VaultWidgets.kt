package com.nostrvault.widget

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
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
import androidx.glance.layout.width
import androidx.glance.text.Text
import androidx.compose.ui.unit.dp
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
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val snapshot = WidgetSnapshotStore.read(context)
        provideContent { GlanceTheme { FeedContent(context, snapshot) } }
    }
}

class FeedReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = FeedWidget()
}

@Composable
private fun FeedContent(context: Context, snapshot: VaultSnapshot) {
    Column(
        modifier = GlanceModifier
            .fillMaxSize()
            .background(WidgetTheme.Background)
            .padding(12.dp),
    ) {
        Row(modifier = GlanceModifier.fillMaxWidth()) {
            Text("Feed", style = WidgetTheme.Title)
            Spacer(GlanceModifier.defaultWeight())
            Text(freshness(snapshot.updatedAt), style = WidgetTheme.Caption)
        }
        Spacer(GlanceModifier.height(8.dp))
        if (snapshot.feed.isEmpty()) {
            Text("Open the app to fill this in", style = WidgetTheme.Caption)
            return@Column
        }
        snapshot.feed.take(4).forEach { note ->
            Column(
                modifier = GlanceModifier
                    .fillMaxWidth()
                    .padding(bottom = 8.dp)
                    .clickable(openApp(context, "note/${note.id}")),
            ) {
                Text(note.displayName, style = WidgetTheme.Caption)
                Text(note.text.take(90), style = WidgetTheme.Body, maxLines = 2)
            }
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
