package com.nostrvault.data.model

import androidx.compose.runtime.Stable
import kotlinx.serialization.Serializable

// ---------------------------------------------------------------------------
// FeedProfile
// ---------------------------------------------------------------------------

@Stable
@Serializable
data class FeedProfile(
    val pubkey: String,
    var name: String? = null,
    var displayName: String? = null,
    var pictureURL: String? = null,
    /** The wide header image (kind-0 `banner`). */
    var bannerURL: String? = null,
    var nip05: String? = null,
    var about: String? = null,
    var lud16: String? = null,
    var lud06: String? = null,
    var website: String? = null,
    /** Epoch millis of the last successful metadata fetch; null for legacy/unstamped entries. */
    var fetchedAt: Long? = null,
    /** created_at (epoch seconds) of the kind-0 this came from; null for older cache entries. */
    var createdAt: Long? = null,
) {
    /** Best display name: display_name > name > truncated pubkey. Computed once at
     *  construction (profiles are replaced via copy(), never mutated in place), so
     *  hot-path reads (~30/frame across feed rows) don't re-run the fallback chain.
     *  Transient, so this stays out of profiles.json. */
    @kotlinx.serialization.Transient
    val rawBestName: String = displayName?.takeIf { it.isNotBlank() }
        ?: name?.takeIf { it.isNotBlank() }
        ?: "${pubkey.take(8)}..."

    /** [rawBestName] as shown: masked while clean mode is on ([com.nostrvault.util.CleanMode]). Never publish this. */
    val bestName: String get() = com.nostrvault.util.CleanMode.shown(rawBestName)
}
