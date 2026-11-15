package com.nostrvault.ui.screens.dm

import android.content.Context
import com.nostrvault.service.DMFileLoader
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * The one locked DM video open right now, in memory only: the thread's inline player and the
 * full-screen viewer share it, so a 100 MB video is opened (and held) once, not twice. Opening
 * another lets the last one go first. The thread clears it when it closes.
 */
object DMOpenedVideo {
    private val lock = Mutex()
    @Volatile private var link: String? = null
    @Volatile private var bytes: ByteArray? = null
    private val _current = kotlinx.coroutines.flow.MutableStateFlow<String?>(null)

    /** The link open now: a tile whose video was let go stops its player, so two aren't held. */
    val current: kotlinx.coroutines.flow.StateFlow<String?> = _current

    /**
     * The opened video for [link] (up to [max]); throws when it can't be fetched or isn't the file
     * sent, and DMFileLoader.TooBig when it is over [max] (a size tag that said less: tap to load).
     */
    suspend fun open(
        context: Context,
        link: String,
        max: Long = com.nostrvault.service.DMFile.MAX_FILE,
        onProgress: ((Long, Long) -> Unit)? = null,
    ): ByteArray =
        lock.withLock {
            bytes?.takeIf { this.link == link }?.let {
                onProgress?.invoke(it.size.toLong(), it.size.toLong())
                return@withLock it
            }
            // Let the last one go before the next is read: two big videos at once is how memory runs out.
            this.link = null
            bytes = null
            _current.value = null
            val opened = DMFileLoader.open(context, link, max, video = true, onProgress = onProgress).first
            this.link = link
            bytes = opened
            _current.value = link
            opened
        }

    fun clear() {
        link = null
        bytes = null
        _current.value = null
    }
}
