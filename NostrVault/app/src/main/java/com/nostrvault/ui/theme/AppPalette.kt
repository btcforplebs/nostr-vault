package com.nostrvault.ui.theme

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * Settings > Appearance > Mode (PLANS/NV_LIGHT_MODE_AND_CUSTOM_COLORS.md).
 * Twin of Apple's AppAppearance.
 *
 * The colour tokens in Color.kt are getters that read [light], so the ~100
 * files that use them flip without changing. It is snapshot state: anything
 * drawn from a token recomposes when the mode changes. Only the main
 * activity's [NostrVaultTheme] writes it.
 */
object AppPalette {
    var light by mutableStateOf(false)

    const val DARK = "dark"
    const val LIGHT = "light"
    const val SYSTEM = "system"

    /** Whether [mode] draws light, given whether the phone is in dark mode. */
    fun isLight(mode: String, systemDark: Boolean): Boolean = when (mode) {
        LIGHT -> true
        SYSTEM -> !systemDark
        else -> false
    }
}
