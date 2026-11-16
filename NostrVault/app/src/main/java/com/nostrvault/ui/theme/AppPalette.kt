package com.nostrvault.ui.theme

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
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

    /**
     * True while the trust globe is the screen on top. The globe stays dark in
     * every mode, so its pills, the dock and the status bar draw dark over it
     * too (Apple forces TrustWebView and the dock dark the same way). Written
     * by NavGraph; [NostrVaultTheme] folds it into [light].
     */
    var overGlobe by mutableStateOf(false)

    /**
     * How many Web of Trust globes are open as dialogs (TrustWebDialog, from a
     * note, a profile, search). Above zero the app draws dark, as for
     * [overGlobe], so the globe's buttons and bars stay readable in Light.
     */
    var globeDialogs by mutableIntStateOf(0)

    /**
     * The mode the user chose, before [overGlobe] folds it to dark: the globe
     * itself draws a daytime sky when this is true. Written by [NostrVaultTheme].
     */
    var lightChosen by mutableStateOf(false)

    /** Settings > Appearance > Accent, as saved in themeColor ("orange" or "#rrggbb"). */
    var accent by mutableStateOf("orange")

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
