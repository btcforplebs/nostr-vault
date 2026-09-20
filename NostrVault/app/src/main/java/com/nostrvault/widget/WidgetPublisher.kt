package com.nostrvault.widget

import android.content.Context
import android.util.Log
import androidx.glance.appwidget.updateAll
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.service.DMService
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.launch
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
                VaultSnapshot(
                    feed = notes.take(FEED_ITEMS).map { note ->
                        VaultSnapshot.SnapshotNote(
                            id = note.id,
                            author = note.pubkey,
                            displayName = profiles[note.pubkey]?.bestName
                                ?: note.pubkey.take(8),
                            // Trimmed here rather than at draw time: the
                            // snapshot is a file the widgets re-read, and a
                            // long-form note would otherwise sit in it whole.
                            text = note.content.trim().take(200),
                            createdAt = note.createdAt.time,
                        )
                    },
                    unreadDMs = unread,
                )
            }
                .debounce(2_000)
                .collect { fresh ->
                    val changed = WidgetSnapshotStore.update(context) { current ->
                        // Keep the relay half; that writer is the service.
                        fresh.copy(relay = current.relay)
                    }
                    if (changed) redraw(context)
                }
        }
    }
}
