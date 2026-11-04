package com.nostrvault.widget

import android.content.Context
import android.graphics.Bitmap
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
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
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Live now: people you follow who are on air, picture + name + stream title;
 * a tap opens the stream in the player. A small widget shows the newest, a
 * wider one up to three (iOS: Your space's Live now panel, #1679).
 */
class LiveNowWidget : GlanceAppWidget() {
    override val sizeMode: SizeMode = SizeMode.Exact

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        var snapshot = WidgetSnapshotStore.read(context)
        // The launcher's half-hourly update, with the app closed: ask once
        // before drawing. With the app open the list is never this old.
        if (System.currentTimeMillis() - snapshot.live.checkedAt > LiveNowRules.STALE_MS) {
            withTimeoutOrNull(REFRESH_BUDGET_MS) {
                runCatching { HomeWidgetRefresher.from(context).refreshFromWidget(live = true) }
                    .onFailure(HomeWidgetRefresher::logFailure)
            }
            snapshot = WidgetSnapshotStore.read(context)
        }
        val live = snapshot.live
        val avatars = loadAvatars(context, live.streams)
        provideContent { GlanceTheme { LiveNowContent(context, live, avatars) } }
    }

    /** Pictures have to exist before the composition runs: it draws once. */
    private suspend fun loadAvatars(context: Context, streams: List<VaultSnapshot.LiveItem>): Map<String, Bitmap> {
        val pictures = WidgetImages.load(
            context,
            streams.mapNotNull { s -> s.hostPicture?.let { WidgetImages.Source(id = s.host, url = it) } },
            maxPixel = AVATAR_PIXELS * 2,
            remoteLimit = LiveNowRules.MAX_ROWS,
        )
        return streams.associate { s ->
            s.host to (
                pictures[s.host]?.let { WidgetImages.square(it, AVATAR_PIXELS, circle = true) }
                    ?: WidgetImages.fallback(s.host, AVATAR_PIXELS, circle = true, strong = 0.9f, weak = 0.45f)
                )
        }
    }

    companion object {
        private const val AVATAR_PIXELS = 112
        private const val REFRESH_BUDGET_MS = 20_000L
    }
}

class LiveNowReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = LiveNowWidget()
}

/** The red of a LIVE pill, as the Live tab draws it. */
private val LiveRed = Color(0xFFFF3B30)

@Composable
private fun LiveNowContent(context: Context, live: VaultSnapshot.LiveNow, avatars: Map<String, Bitmap>) {
    val wide = LocalSize.current.width >= 200.dp
    Column(
        modifier = GlanceModifier
            .fillMaxSize()
            .background(WidgetTheme.Background)
            .padding(12.dp)
            .clickable(openApp(context, "feed")),
    ) {
        Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Box(GlanceModifier.size(7.dp).background(LiveRed).cornerRadius(4.dp)) {}
            Spacer(GlanceModifier.width(6.dp))
            Text("Live now", style = WidgetTheme.Title, maxLines = 1)
        }
        Spacer(GlanceModifier.height(8.dp))
        val streams = live.streams
        when {
            live.checkedAt <= 0L -> Text("Open Nostr Vault to see who is live", style = WidgetTheme.Caption)
            streams.isEmpty() -> Text(LiveNowRules.emptyLine(live.followsSomeone), style = WidgetTheme.Caption)
            !wide -> SmallStream(context, streams.first(), avatars[streams.first().host])
            else -> streams.take(LiveNowRules.MAX_ROWS).forEachIndexed { i, s ->
                if (i > 0) Spacer(GlanceModifier.height(8.dp))
                StreamRow(context, s, avatars[s.host])
            }
        }
    }
}

/** Small: the newest stream alone, picture over name and a two-line title. */
@Composable
private fun SmallStream(context: Context, stream: VaultSnapshot.LiveItem, avatar: Bitmap?) {
    Column(modifier = GlanceModifier.fillMaxWidth().clickable(openApp(context, LiveNowRules.destination(stream.address)))) {
        if (avatar != null) {
            Image(ImageProvider(avatar), contentDescription = null, modifier = GlanceModifier.size(40.dp))
            Spacer(GlanceModifier.height(6.dp))
        }
        Text(stream.hostName, maxLines = 1, style = NameStyle)
        Text(stream.title, maxLines = 2, style = TitleStyle)
    }
}

/** Medium: one row per stream, picture beside name and a one-line title. */
@Composable
private fun StreamRow(context: Context, stream: VaultSnapshot.LiveItem, avatar: Bitmap?) {
    Row(
        modifier = GlanceModifier.fillMaxWidth().clickable(openApp(context, LiveNowRules.destination(stream.address))),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (avatar != null) {
            Image(ImageProvider(avatar), contentDescription = null, modifier = GlanceModifier.size(28.dp))
            Spacer(GlanceModifier.width(8.dp))
        }
        Column(modifier = GlanceModifier.defaultWeight()) {
            Text(stream.hostName, maxLines = 1, style = NameStyle)
            Text(stream.title, maxLines = 1, style = TitleStyle)
        }
    }
}

private val NameStyle = TextStyle(color = ColorProvider(WidgetTheme.Primary), fontSize = 12.sp, fontWeight = FontWeight.Medium)
private val TitleStyle = TextStyle(color = ColorProvider(WidgetTheme.Primary.copy(alpha = 0.72f)), fontSize = 12.sp)
