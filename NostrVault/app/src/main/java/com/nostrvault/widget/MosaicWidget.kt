package com.nostrvault.widget

import android.content.Context
import android.graphics.Bitmap
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalSize
import androidx.glance.action.ActionParameters
import androidx.glance.action.actionParametersOf
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.action.ActionCallback
import androidx.glance.appwidget.action.actionRunCallback
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.state.updateAppWidgetState
import androidx.glance.background
import androidx.glance.currentState
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.ContentScale
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

/**
 * Mosaic: your Blossom media as a grid, with the Media tab's filter chips
 * across the top and its Magic Paste on the right. Port of iOS MosaicWidget.
 *
 * Every tile's bitmap is decoded in [provideGlance] — shrunk, off the main
 * thread — because the composition draws once and cannot wait on a decode, let
 * alone a download. All of the snapshot's tiles are loaded, not just the ones
 * the current chip shows, so a chip tap only recomposes.
 */
class MosaicWidget : GlanceAppWidget() {
    // Exact: the grid is planned from the real cell size, so a resize to a
    // shape no breakpoint anticipated still fills edge to edge.
    override val sizeMode: SizeMode = SizeMode.Exact

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val snapshot = WidgetSnapshotStore.read(context)
        val tiles = snapshot.media.take(MosaicGrid.MAX_TILES)
        val loaded = WidgetImages.load(
            context,
            tiles.map { WidgetImages.Source(it.id, it.url, it.localPath) },
            maxPixel = TILE_PIXELS,
        )
        // No bytes: a blob on a host that did not answer, or not a picture at
        // all. A tile tinted to its id keeps the grid reading as media.
        val images = tiles.associate { tile ->
            tile.id to (loaded[tile.id]
                ?: WidgetImages.fallback(tile.id, 48, circle = false, strong = 0.65f, weak = 0.25f))
        }
        provideContent {
            GlanceTheme {
                val prefs = currentState<Preferences>()
                MosaicContent(
                    context = context,
                    snapshot = snapshot,
                    images = images,
                    filter = MosaicFilter.fromKey(prefs[FILTER_KEY]),
                    config = MosaicConfig.from(prefs.asLookup()),
                )
            }
        }
    }

    companion object {
        /** Big enough for an extra-large widget's tile on a dense screen, small enough for 18 of them. */
        const val TILE_PIXELS = 240
        val FILTER_KEY = stringPreferencesKey("mosaic.filter")
    }
}

class MosaicReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = MosaicWidget()
}

/**
 * A filter chip tap. Writes the choice to every Mosaic on the home screen, as
 * iOS does with its one shared pref — a small Mosaic has no room for chips and
 * inherits whatever a bigger one is set to.
 */
class MosaicFilterAction : ActionCallback {
    override suspend fun onAction(context: Context, glanceId: GlanceId, parameters: ActionParameters) {
        val filter = MosaicFilter.fromKey(parameters[FILTER_PARAM])
        val widget = MosaicWidget()
        GlanceAppWidgetManager(context).getGlanceIds(MosaicWidget::class.java).forEach { id ->
            updateAppWidgetState(context, id) { it[MosaicWidget.FILTER_KEY] = filter.name }
            widget.update(context, id)
        }
    }

    companion object {
        val FILTER_PARAM = ActionParameters.Key<String>("filter")
    }
}

private val GAP = 4.dp
private val PAD = 8.dp
private val CHROME_HEIGHT = 26.dp
private val STRIP = 44.dp

@Composable
private fun MosaicContent(
    context: Context,
    snapshot: VaultSnapshot,
    images: Map<String, Bitmap>,
    filter: MosaicFilter,
    config: MosaicConfig,
) {
    val size = LocalSize.current
    // Small is too narrow for four chips and a paste button; it stays a pure
    // grid (iOS does the same).
    val showsChrome = size.width >= 200.dp && size.height >= 140.dp
    val visible = snapshot.media.filter { filter.accepts(it.kind) }

    Column(
        modifier = GlanceModifier
            .fillMaxSize()
            .background(WidgetTheme.Background)
            .padding(PAD),
    ) {
        if (showsChrome) {
            Chrome(context, filter)
            Spacer(GlanceModifier.height(6.dp))
        }
        val gridWidth = size.width - PAD * 2
        val gridHeight = size.height - PAD * 2 - if (showsChrome) CHROME_HEIGHT + 6.dp else 0.dp
        if (visible.isEmpty()) {
            Box(
                modifier = GlanceModifier.fillMaxSize().clickable(openApp(context, "media")),
                contentAlignment = Alignment.Center,
            ) {
                Text(emptyMessage(snapshot, filter), style = WidgetTheme.Caption)
            }
        } else {
            val corner = if (config.rounded) 8.dp else 0.dp
            when (config.style) {
                MosaicStyle.GRID -> Grid(context, visible, images, gridWidth, gridHeight, corner)
                MosaicStyle.FEATURED -> Featured(context, visible, images, gridWidth, gridHeight, corner)
            }
        }
    }
}

@Composable
private fun Grid(
    context: Context,
    tiles: List<VaultSnapshot.MediaTile>,
    images: Map<String, Bitmap>,
    width: Dp,
    height: Dp,
    corner: Dp,
) {
    val plan = MosaicGrid.plan(width.value, height.value, GAP.value)
    val shown = tiles.take(plan.capacity)
    val tile = plan.tileDp.dp
    Column {
        shown.chunked(plan.columns).forEachIndexed { rowIndex, row ->
            if (rowIndex > 0) Spacer(GlanceModifier.height(GAP))
            Row {
                row.forEachIndexed { i, item ->
                    if (i > 0) Spacer(GlanceModifier.width(GAP))
                    images[item.id]?.let { Tile(context, item, it, tile, tile, corner) }
                }
            }
        }
    }
}

/**
 * One large tile, and a strip of small ones under it when the widget is tall
 * enough to spare the row (iOS MosaicView's featured style).
 */
@Composable
private fun Featured(
    context: Context,
    tiles: List<VaultSnapshot.MediaTile>,
    images: Map<String, Bitmap>,
    width: Dp,
    height: Dp,
    corner: Dp,
) {
    val strip = MosaicGrid.featuredStripCount(width.value, height.value, STRIP.value, GAP.value)
        .coerceAtMost(tiles.size - 1)
    val heroHeight = if (strip > 0) height - STRIP - GAP else height
    val hero = tiles.first()
    Column {
        images[hero.id]?.let { Tile(context, hero, it, width, heroHeight, corner) }
        if (strip > 0) {
            Spacer(GlanceModifier.height(GAP))
            // Equal shares of the row rather than squares, so the strip always
            // fits across and never pushes a tile off the edge.
            val small = (width - GAP * (strip - 1)) / strip
            Row {
                tiles.drop(1).take(strip).forEachIndexed { i, item ->
                    if (i > 0) Spacer(GlanceModifier.width(GAP))
                    images[item.id]?.let { Tile(context, item, it, small, STRIP, corner) }
                }
            }
        }
    }
}

@Composable
private fun Tile(
    context: Context,
    tile: VaultSnapshot.MediaTile,
    bitmap: Bitmap,
    width: Dp,
    height: Dp,
    corner: Dp,
) {
    // Every tile opens the Media tab, as on iOS: the widget's job is to get
    // you to your media, and the gallery is where an item can be acted on.
    Box(
        modifier = GlanceModifier
            .size(width, height)
            .cornerRadius(corner)
            .clickable(openApp(context, "media")),
        contentAlignment = Alignment.Center,
    ) {
        Image(
            provider = ImageProvider(bitmap),
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = GlanceModifier.fillMaxSize(),
        )
        if (tile.kind == MediaKind.VIDEO) {
            Text(
                "▶",
                style = TextStyle(
                    color = ColorProvider(Color.White.copy(alpha = 0.9f)),
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Bold,
                ),
            )
        }
    }
}

/** The Media tab's filter row, plus its Magic Paste, on the widget face. */
@Composable
private fun Chrome(context: Context, selected: MosaicFilter) {
    Row(
        modifier = GlanceModifier.fillMaxWidth().height(CHROME_HEIGHT),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        MosaicFilter.entries.forEach { option ->
            val on = option == selected
            Box(
                modifier = GlanceModifier
                    .padding(end = 4.dp)
                    .clickable(
                        actionRunCallback<MosaicFilterAction>(
                            actionParametersOf(MosaicFilterAction.FILTER_PARAM to option.name)
                        )
                    ),
            ) {
                Text(
                    option.label,
                    maxLines = 1,
                    style = TextStyle(
                        color = ColorProvider(if (on) Color.White else WidgetTheme.Secondary),
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Medium,
                    ),
                    modifier = GlanceModifier
                        .background(if (on) WidgetTheme.Accent.copy(alpha = 0.85f) else Color.White.copy(alpha = 0.08f))
                        .cornerRadius(10.dp)
                        .padding(horizontal = 8.dp, vertical = 3.dp),
                )
            }
        }
        Spacer(GlanceModifier.defaultWeight())
        // Magic Paste cannot run inside a widget — there is no surface to
        // read the clipboard from. This opens the Media tab with the app's
        // own paste already running, which is the same single tap.
        Text(
            "Paste",
            maxLines = 1,
            style = TextStyle(
                color = ColorProvider(WidgetTheme.Accent),
                fontSize = 11.sp,
                fontWeight = FontWeight.Medium,
            ),
            modifier = GlanceModifier
                .background(Color.White.copy(alpha = 0.08f))
                .cornerRadius(10.dp)
                .padding(horizontal = 8.dp, vertical = 3.dp)
                .clickable(openApp(context, "mediapaste")),
        )
    }
}

/**
 * "Nothing here" and "nothing matching this chip" are different problems: one
 * is a prompt to upload, the other to change the filter.
 */
private fun emptyMessage(snapshot: VaultSnapshot, filter: MosaicFilter): String = when {
    snapshot.updatedAt <= 0L -> "Open Nostr Vault to load your media"
    filter != MosaicFilter.ALL && snapshot.media.isNotEmpty() -> "No ${filter.label.lowercase()} yet"
    else -> "No media on your relay yet"
}
