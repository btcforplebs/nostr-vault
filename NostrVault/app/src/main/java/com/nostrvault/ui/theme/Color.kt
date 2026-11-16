package com.nostrvault.ui.theme

import androidx.compose.ui.graphics.Color

/**
 * Port of Theming.swift + PlatformCompat.swift color definitions.
 * The elevation ramp (surface0-3, borderHairline, borderStrong) matches
 * Theming.swift exactly.
 */

// ---------------------------------------------------------------------------
// Theme color schemes (port of AppTheme enum in Theming.swift)
// ---------------------------------------------------------------------------

data class NostrVaultColorScheme(
    val primary: Color,
    val primaryLight: Color,
    val primaryDark: Color,
    val primaryPale: Color,
    /** Accent text (#tags, links, mentions): [primary] in Dark; in Light a darker
     *  shade when the accent is too pale to read on white (AccentPalette). */
    val primaryText: Color = primary,
)

/**
 * The app has exactly one appearance: OLED black with the orange accent.
 *
 * This was a six-way colour picker (purple/blue/green/orange/pink/slate) paired
 * with an OLED toggle. Both are gone. The enum survives only so `themeColor`
 * keeps resolving — a config saved under any retired key falls through
 * [fromKey] to [DEFAULT], so old installs migrate silently.
 */
enum class AppTheme(
    val key: String,
    val displayName: String,
    val colors: NostrVaultColorScheme,
    val lightColors: NostrVaultColorScheme,
) {
    SUNSET_ORANGE(
        key = "orange",
        displayName = "Sunset Orange",
        // Dark: the orange's neon (AccentPalette.neonHex), fills and text.
        colors = NostrVaultColorScheme(
            primary = Color(0xFFEA7013),
            primaryLight = Color(0xFFFF8A3A),
            primaryDark = Color(0xFFC04A00),
            primaryPale = Color(0xFFEA7013).copy(alpha = 0.10f),
            primaryText = Color(0xFFEA7013),
        ),
        // Light: fills are the exact orange; only its text is darkened so it
        // reads on the paper page (#C35400 is 4.5:1 on white).
        lightColors = NostrVaultColorScheme(
            primary = Color(0xFFE67326),
            primaryLight = Color(0xFFE67326),
            primaryDark = Color(0xFFC35400),
            primaryPale = Color(0xFFE67326).copy(alpha = 0.10f),
            primaryText = Color(0xFFC35400),
        ),
    ),
    ;

    companion object {
        val DEFAULT = SUNSET_ORANGE

        fun fromKey(key: String): AppTheme =
            entries.find { it.key == key } ?: DEFAULT
    }
}

// ---------------------------------------------------------------------------
// Elevation ramp (port of Theming.swift surface0-3 / borderHairline / borderStrong)
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Ink, shade and labels (twin of Theming.swift ink / shade / onAccent)
//
// Each flips with Settings > Appearance > Mode (AppPalette.light)
// (PLANS/NV_LIGHT_MODE_AND_CUSTOM_COLORS.md).
// Pick by what the colour sits on:
// - Ink: text, icons, strokes and tints on the app's own surfaces (Surface0-3,
//   cards, rows, sheets, bars). Use Ink.copy(alpha = x) for dimmer steps.
// - Shade: shadows and dimming drawn over the app's own surfaces.
// - OnAccent: a label on an accent fill (primary buttons, badges).
// - Plain Color.White / Color.Black: only where the backdrop is dark in every
//   mode, such as text over a photo or video, the media viewer, the player, the
//   trust globe, or a black scrim.
// ---------------------------------------------------------------------------

/** One colour per mode, for the few fills that aren't a ramp step. */
fun lightOr(light: Color, dark: Color): Color = if (AppPalette.light) light else dark

val Ink: Color get() = if (AppPalette.light) Color.Black else Color.White
val Shade: Color get() = if (AppPalette.light) Color(0xFF3C2814) else Color.Black  // light: warm brown-grey
val OnAccent: Color get() = AccentPalette.ramp(AppPalette.accent, AppPalette.light).onAccent

val Surface0: Color get() = if (AppPalette.light) AccentPalette.paper(AppPalette.accent) else Color(0xFF000000) // page (light: warm paper + 5% accent)
val Surface1: Color get() = if (AppPalette.light) Color(0xFFFFFFFF) else Color(0xFF1C1C1E) // resting card
val Surface2: Color get() = if (AppPalette.light) Color(0xFFEFE9E2) else Color(0xFF2C2C2E) // raised
val Surface3: Color get() = if (AppPalette.light) Color(0xFFE2DBD3) else Color(0xFF3A3A3C) // highest
val BorderHairline: Color get() = if (AppPalette.light) Color(0xFF1C1C1E).copy(alpha = 0.16f) else Color.White.copy(alpha = 0.14f)
val BorderStrong: Color get() = if (AppPalette.light) Color(0xFF3A3A3C).copy(alpha = 0.6f) else Color.White.copy(alpha = 0.36f)

// ---------------------------------------------------------------------------
// Platform background colors (port of PlatformCompat.swift)
// ---------------------------------------------------------------------------

// platformSecondaryGroupedBackground -> surface1, platformTertiaryGroupedBackground
// -> surface2 on the Swift side (PlatformCompat.swift) — "Secondary"/"Tertiary" name
// UIKit's own grouped-background tiers, not ramp step numbers.
val WindowBackground: Color get() = Surface0
val SecondaryGroupedBg: Color get() = Surface1
val TertiaryGroupedBg: Color get() = Surface2
val SeparatorColor: Color get() = if (AppPalette.light) Color(0xFFDDD6CE) else Color(0xFF333338)

// Standard card
val CardBackground: Color get() = Surface1
val CardBorder: Color get() = BorderHairline

// OLED variants (toggled by user preference) — same ramp; page/card no longer invert.
val OledCardBackground: Color get() = Surface1
val OledCardBorder: Color get() = BorderHairline

// Console / dashboard — matches platformConsoleHeaderBackground -> surface2.
val ConsoleHeaderBg: Color get() = Surface2

// Text colors
val PrimaryText: Color get() = Ink
val SecondaryText: Color get() = Ink.copy(alpha = 0.60f)
val TertiaryText: Color get() = Ink.copy(alpha = 0.40f)
val PlaceholderText: Color get() = Ink.copy(alpha = 0.25f)

// Status colors
val SuccessGreen = Color(0xFF34C759)
val WarningYellow = Color(0xFFFFCC00)
val ErrorRed = Color(0xFFFF3B30)
val InfoBlue = Color(0xFF007AFF)

// Engagement action colors: iOS's system red / green / orange in dark mode,
// which is all the app has (the light-mode values read dull on black).
val LikeRed = Color(0xFFFF453A)
val RepostGreen = Color(0xFF30D158)
// The one zap gold (#F2A33A), shared with iOS havenZapGold: a warm step off
// the brand orange, so sats read as their own thing inside the palette.
val ZapOrange = Color(0xFFF2A33A)

// Wizard accent (setup flow)
val WizardOrange = Color(0xFFE67326)
val WizardOrangeDark = Color(0xFFB35214)
