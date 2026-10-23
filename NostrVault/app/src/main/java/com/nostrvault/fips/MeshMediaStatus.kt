package com.nostrvault.fips

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/**
 * What a photo shows in its place while it isn't drawn: the web's `MeshBox`
 * (web-vault MediaImage.jsx) and iOS `MeshMediaPhase`, same words.
 */
enum class MeshMediaPhase {
    /** The URL failed (or is a `.fips` link) and the author's vault is being asked over the mesh. */
    MeshLookup,

    /** The mesh was asked and gave up. */
    Unreached;

    fun text(video: Boolean = false): String = when (this) {
        MeshLookup -> if (video) "Loading video over FIPS…" else "Loading image over FIPS…"
        Unreached -> "Couldn't reach the owner's vault"
    }
}

/**
 * Which blobs are being read over the mesh right now, by sha256. The
 * interceptor runs on OkHttp's threads and knows nothing of the view drawing
 * the photo; every view showing a URL with that hash in its path reads the
 * phase here, so the feed, a thread, the Vault, a profile and the full-screen
 * viewer all say the same thing about the same photo (iOS #1079).
 */
object MeshMediaStatus {
    private val _phases = MutableStateFlow<Map<String, MeshMediaPhase>>(emptyMap())
    val phases: StateFlow<Map<String, MeshMediaPhase>> = _phases.asStateFlow()

    fun set(sha256: String, phase: MeshMediaPhase) {
        _phases.update { it + (sha256 to phase) }
    }

    /** The photo arrived (or its load was dropped): nothing to say over it. */
    fun clear(sha256: String) {
        _phases.update { if (sha256 in it) it - sha256 else it }
    }

    /** The phase for a photo [url], by the hash its path names; null when there is nothing to say. */
    fun phaseFor(phases: Map<String, MeshMediaPhase>, url: String?): MeshMediaPhase? =
        url?.let { FipsMediaRouter.sha256In(it) }?.let { phases[it] }
}
