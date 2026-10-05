package com.nostrvault.widget

import android.content.Context
import android.util.Log
import androidx.glance.appwidget.updateAll
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedNote
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.service.DMService
import com.nostrvault.service.FeedService
import com.nostrvault.service.MediaCacheService
import com.nostrvault.service.NostrService
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import java.io.File
import java.io.FileInputStream
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Keeps the widget snapshot current while the app is alive.
 *
 * A widget cannot fetch anything itself — it draws once from whatever is on
 * disk — so the app is responsible for leaving behind numbers that were true
 * recently, and the widgets print how old they are rather than implying they
 * are live.
 *
 * The relay half is published separately by the foreground service (see
 * [publishRelayStats]), because that keeps running when the activity is gone
 * and it is the half that changes on its own.
 */
@Singleton
class WidgetPublisher @Inject constructor(
    @ApplicationContext private val context: Context,
    private val feedService: FeedService,
    private val dmService: DMService,
    private val nostrService: NostrService,
    private val configStore: ConfigStore,
    private val mediaCache: MediaCacheService,
) {
    companion object {
        private const val TAG = "WidgetPublisher"
        private const val FEED_ITEMS = 10

        /**
         * Relay stats, published from wherever the relay is running — the
         * foreground service has no Hilt graph, so this is a plain function on
         * the store rather than an injected dependency.
         */
        suspend fun publishRelayStats(context: Context) {
            val changed = WidgetSnapshotStore.update(context) {
                it.copy(
                    relay = VaultSnapshot.RelayStats(
                        running = RelayForegroundService.relayStatus.value ==
                            RelayForegroundService.RelayStatus.RUNNING,
                        eventsStored = RelayForegroundService.eventsStored.value,
                        connections = RelayForegroundService.connections.value,
                    )
                )
            }
            if (changed) redraw(context)
        }

        private suspend fun redraw(context: Context) {
            runCatching {
                VaultPulseWidget().updateAll(context)
                FeedWidget().updateAll(context)
                MosaicWidget().updateAll(context)
                // The DMs tile carries the unread badge.
                QuickActionsWidget().updateAll(context)
            }.onFailure { Log.w(TAG, "widget redraw failed: ${it.message}") }
        }
    }

    /**
     * Collect while [scope] lives. Debounced: the feed changes far faster than
     * a home screen is looked at, and every publish is a file write plus a
     * redraw of every installed widget.
     */
    fun start(scope: CoroutineScope) {
        scope.launch {
            combine(
                feedService.notes,
                dmService.totalUnreadCountFlow,
                nostrService.profiles,
            ) { notes, unread, profiles ->
                val me = configStore.activeAccountHexPubkey.value
                fun snap(note: FeedNote) = VaultSnapshot.SnapshotNote(
                    id = note.id,
                    author = note.pubkey,
                    displayName = profiles[note.pubkey]?.bestName
                        ?: note.pubkey.take(8),
                    // Trimmed here rather than at draw time: the snapshot is
                    // a file the widgets re-read, and a long-form note would
                    // otherwise sit in it whole. Newlines collapsed: a widget
                    // row has no paragraph rendering.
                    text = note.content.replace('\n', ' ').trim().take(200),
                    createdAt = note.createdAt.time,
                    authorPicture = profiles[note.pubkey]?.pictureURL?.takeIf { it.isNotBlank() },
                )
                VaultSnapshot(
                    // Top-level notes only, as on iOS: a reply out of its
                    // thread reads as an answer to a question the widget
                    // cannot show.
                    feed = notes.asSequence().filter { !it.isReply }.take(FEED_ITEMS).map(::snap).toList(),
                    // Mentions keep replies: a reply to your note is the most
                    // common way someone mentions you at all.
                    mentions = notes.take(40)
                        .filter { isMentionOf(me, it.pubkey, it.tags) }
                        .take(FEED_ITEMS).map(::snap),
                    unreadDMs = unread,
                )
            }
                .debounce(2_000)
                // Media is a directory listing plus a header read per tile —
                // disk work that has no business on the main thread.
                .map { it.copy(media = mediaTiles(feedService.notes.value)) }
                .flowOn(Dispatchers.IO)
                .collect { fresh ->
                    val changed = WidgetSnapshotStore.update(context) { current ->
                        // Keep the relay half; that writer is the service.
                        fresh.copy(relay = current.relay)
                    }
                    if (changed) redraw(context)
                }
        }
    }

    /**
     * Mosaic's tiles, newest first (iOS NVWidgetBridge.mediaTiles).
     *
     * Blossom first — those are the blobs actually on your relay, which is
     * what the widget claims to show — read straight off disk rather than
     * through the Media tab's view model, so a user who has never opened that
     * tab still gets a grid. Media from your own recent notes fills in behind,
     * deduped by blob hash because your uploads normally appear in both.
     */
    private fun mediaTiles(recent: List<FeedNote>): List<VaultSnapshot.MediaTile> {
        val tiles = mutableListOf<VaultSnapshot.MediaTile>()
        val seen = mutableSetOf<String>()

        val config = configStore.config.value
        val blossomDir = config.relayDataDir?.let { File(it, config.blossomPath) }
        val blobs = blossomDir?.listFiles()
            ?.filter { f ->
                f.isFile && f.nameWithoutExtension.let { n -> n.length == 64 && n.all { it in "0123456789abcdef" } }
            }
            ?.sortedByDescending { it.lastModified() }
            .orEmpty()
        for (file in blobs) {
            val kind = sniff(file)
            // Audio and documents have nothing to draw.
            if (kind == MediaKind.OTHER) continue
            val hash = file.nameWithoutExtension
            if (!seen.add(hash)) continue
            tiles += VaultSnapshot.MediaTile(id = hash, url = hash, localPath = file.absolutePath, kind = kind)
            if (tiles.size >= MosaicGrid.MAX_TILES) return tiles
        }

        val me = configStore.activeAccountHexPubkey.value
        if (me.isEmpty()) return tiles
        for (note in recent.take(40)) {
            if (note.pubkey != me) continue
            for (url in note.mediaURLs) {
                val hash = BLOSSOM_HASH.find(url)?.value
                if (!seen.add(hash ?: url)) continue
                val local = runCatching { mediaCache.localFileUrl(url) }.getOrNull()
                tiles += VaultSnapshot.MediaTile(
                    id = hash ?: (note.id + url),
                    url = url,
                    localPath = local?.absolutePath,
                    // Note media carries no sniffed type unless the bytes are
                    // here; the chips would rather show it under All only than
                    // mislabel it.
                    kind = local?.let { sniff(it) },
                )
                if (tiles.size >= MosaicGrid.MAX_TILES) return tiles
            }
        }
        return tiles
    }

    private fun sniff(file: File): MediaKind? = runCatching {
        val header = ByteArray(12)
        val n = FileInputStream(file).use { it.read(header) }
        if (n < 4) null else MediaKind.fromHeader(header)
    }.getOrNull()
}

private val BLOSSOM_HASH = Regex("[0-9a-f]{64}")
