package com.nostrvault.widget

import android.content.Context
import android.util.Log
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File

/**
 * Everything the home-screen widgets draw, in one file the app writes and the
 * widgets read.
 *
 * iOS has to squeeze this through the keychain in a 180 KB budget because its
 * widget extension is a separate process with no App Group. Glance runs inside
 * the app process, so this is just a file in filesDir — no size ceiling worth
 * engineering around, and no thumbnail downsampling.
 *
 * Fields mirror NVWidgetSnapshot on iOS so the two platforms show the same
 * numbers. Where iOS hardcodes a placeholder (lightning balance, price) this
 * leaves the field out entirely rather than shipping a widget that displays a
 * zero it invented. Zaps today is counted here from your relay
 * ([zapsToday]); iOS still writes 0 for it.
 */
@Serializable
data class VaultSnapshot(
    val updatedAt: Long = 0L,
    val relay: RelayStats = RelayStats(),
    val feed: List<SnapshotNote> = emptyList(),
    val mentions: List<SnapshotNote> = emptyList(),
    val unreadDMs: Int = 0,
    /** Mosaic's tiles, newest first. See WidgetPublisher.mediaTiles. */
    val media: List<MediaTile> = emptyList(),
    /** Zaps received since local midnight (iOS `wallet.zapsReceived24h`). See ZapsTodayCounter. */
    val zapsToday: ZapCount = ZapCount(),
) {
    /**
     * A count and the day it belongs to. A widget drawn after midnight shows
     * 0 until the next count, rather than yesterday's number.
     */
    @Serializable
    data class ZapCount(
        val account: String = "",
        /** Local midnight the count started from, in epoch seconds. */
        val dayStart: Long = 0L,
        val count: Int = 0,
    ) {
        /** The count for the day that started at [todayStart]: 0 once the day has changed. */
        fun on(todayStart: Long): Int = if (dayStart == todayStart) count else 0

        /**
         * This count when it is [account]'s for the day that started at
         * [todayStart]; otherwise a 0 for them. Written the moment the
         * account or the day changes, so the widget never shows another
         * account's zaps or yesterday's while the next count is pending, or
         * when the relay can't give one.
         */
        fun heldFor(account: String, todayStart: Long): ZapCount =
            if (account == this.account && dayStart == todayStart) this else ZapCount(account, todayStart, 0)
    }

    @Serializable
    data class RelayStats(
        /**
         * True when the relay is actually serving. On Android this is a real
         * live/not-live signal: RelayForegroundService keeps the relay up in
         * the background. iOS cut its equivalent widget because it cannot.
         */
        val running: Boolean = false,
        val eventsStored: Int = 0,
        val connections: Int = 0,
    )

    @Serializable
    data class SnapshotNote(
        val id: String,
        val author: String,
        val displayName: String,
        val text: String,
        val createdAt: Long,
        /** The author's profile picture, fetched and shrunk by the feed widget's provider. */
        val authorPicture: String? = null,
    )

    /**
     * One Mosaic tile. [localPath] is set when the bytes are on this device
     * (the relay's Blossom store or the media cache) — the widget draws those
     * straight off disk. Anything else is fetched by the widget's provider.
     */
    @Serializable
    data class MediaTile(
        val id: String,
        val url: String,
        val localPath: String? = null,
        /** Null when nothing sniffed it: shown under All, hidden by the narrower chips. */
        val kind: MediaKind? = null,
    )
}

/**
 * Reads and writes the snapshot. Every write goes through [update] so two
 * writers — the activity and the relay service, which do not know about each
 * other — cannot clobber each other's half of the file.
 */
object WidgetSnapshotStore {
    private const val TAG = "WidgetSnapshot"
    private const val FILE_NAME = "widget-snapshot.json"

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val lock = Any()

    private fun file(context: Context) = File(context.filesDir, FILE_NAME)

    fun read(context: Context): VaultSnapshot = synchronized(lock) {
        val f = file(context)
        if (!f.exists()) return VaultSnapshot()
        return try {
            json.decodeFromString<VaultSnapshot>(f.readText())
        } catch (e: Exception) {
            // A snapshot written by an older build is not worth crashing a
            // widget over; an empty one renders as "no data yet".
            Log.w(TAG, "unreadable snapshot, starting fresh: ${e.message}")
            VaultSnapshot()
        }
    }

    /**
     * @return true when the stored snapshot changed, so callers can skip
     *   asking Glance to redraw when nothing moved.
     */
    fun update(context: Context, transform: (VaultSnapshot) -> VaultSnapshot): Boolean =
        synchronized(lock) {
            val current = read(context)
            val next = transform(current).copy(updatedAt = System.currentTimeMillis())
            // updatedAt always moves, so compare everything else.
            if (next.copy(updatedAt = 0) == current.copy(updatedAt = 0)) return false
            return try {
                val tmp = File(context.filesDir, "$FILE_NAME.tmp")
                tmp.writeText(json.encodeToString(VaultSnapshot.serializer(), next))
                tmp.renameTo(file(context))
                true
            } catch (e: Exception) {
                Log.w(TAG, "could not write snapshot: ${e.message}")
                false
            }
        }
}
