package com.nostrvault.ui.theme

/**
 * The home-screen icon follows the accent (Logen, 2026-11-17): one launcher
 * alias per [AccentPalette.presets] colour (AndroidManifest.xml, .Launcher*);
 * a colour from the wheel uses the nearest of them. Off by default. Twin of
 * IconAccent.swift, same nearest-colour rule. Pure, so unit tests check it;
 * IconAccentApply switches the aliases.
 */
object IconAccent {
    /** The launcher alias for each preset, in [AccentPalette.presets] order (art: RESEARCH/NV_ACCENT_ICONS). */
    val aliases: List<Pair<String, String>> = listOf(
        "#e67326" to "LauncherDefault", "#ffb800" to "LauncherGold", "#3ddc84" to "LauncherGreen",
        "#00c2b8" to "LauncherTeal", "#2e7dff" to "LauncherBlue", "#662482" to "LauncherPurple",
        "#ff2d87" to "LauncherPink", "#a8071a" to "LauncherRed",
    )

    const val DEFAULT_ALIAS = "LauncherDefault"

    /** Lightness counts a quarter, so hue and colourfulness decide (pure red is Blood red, not Pink). */
    const val LIGHTNESS_WEIGHT = 0.25

    /** The preset closest to [hex] by OKLab distance. A preset is its own nearest. */
    fun nearestPresetHex(hex: String): String {
        val p = AccentPalette.lab(hex)
        return aliases.minBy { (preset, _) ->
            val q = AccentPalette.lab(preset)
            val dL = (p[0] - q[0]) * LIGHTNESS_WEIGHT
            dL * dL + (p[1] - q[1]) * (p[1] - q[1]) + (p[2] - q[2]) * (p[2] - q[2])
        }.first
    }

    /** The alias that should be enabled: the app's own icon when [follows] is off, else the nearest preset's. */
    fun aliasFor(accentSetting: String, follows: Boolean): String {
        if (!follows) return DEFAULT_ALIAS
        val nearest = nearestPresetHex(AccentPalette.hex(accentSetting))
        return aliases.first { it.first == nearest }.second
    }
}
