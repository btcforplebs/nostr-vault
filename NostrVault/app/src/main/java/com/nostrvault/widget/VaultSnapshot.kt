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
 * numbers. Where iOS hardcodes a placeholder (lightning balance, 24h zaps,
 * price) this leaves the field out entirely rather than shipping a widget that
 * displays a zero it invented.
 */
@Serializable
data class VaultSnapshot(
    val updatedAt: Long = 0L,
    val relay: RelayStats = RelayStats(),
    val feed: List<SnapshotNote> = emptyList(),
    val mentions: List<SnapshotNote> = emptyList(),
    val unreadDMs: Int = 0,
) {
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
