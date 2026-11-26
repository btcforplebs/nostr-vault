package com.nostrvault.service.media

/**
 * Settings > Media & Cache > Upload Quality (Logen 2026-11-26, RESEARCH NV_UPLOAD_COMPRESSION §6).
 * One setting, no per-attachment switch:
 * - "standard" (the default): notes, share, live chat and DM photos are shrunk ([ImageCompressor]),
 *   videos too ([VideoCompressor]).
 * - "original": they go up as they are.
 * Location is removed either way ([com.nostrvault.service.MediaPrivacy.removeLocation] runs after).
 * The Media tab always sends originals and doesn't read this.
 *
 * [current] is set from the config in NostrVaultApp, as LocalBlossomCache is; until the
 * config has loaded it is Standard.
 * Apple twin: `Views/Settings/MediaUploadQualitySettingsView.swift` (plan A4).
 */
object UploadQuality {
    const val STANDARD = "standard"
    const val ORIGINAL = "original"

    @Volatile var current: ImageCompressor.Quality = ImageCompressor.Quality.STANDARD

    /** The saved setting as a quality; anything unknown is Standard. */
    fun from(setting: String): ImageCompressor.Quality =
        if (setting == ORIGINAL) ImageCompressor.Quality.ORIGINAL else ImageCompressor.Quality.STANDARD

    /** The setting as one of [STANDARD] / [ORIGINAL]. */
    fun normalized(setting: String): String = if (setting == ORIGINAL) ORIGINAL else STANDARD

    /** The words beside the row in Media & Cache. */
    fun label(setting: String): String = if (from(setting) == ImageCompressor.Quality.ORIGINAL) "Original" else "Standard"
}
