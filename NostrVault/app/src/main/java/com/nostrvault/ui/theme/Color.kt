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
) {
    SUNSET_ORANGE(
        key = "orange",
        displayName = "Sunset Orange",
        colors = NostrVaultColorScheme(
            primary = Color(0xFFE67326),
            primaryLight = Color(0xFFFA9447),
            primaryDark = Color(0xFFB35214),
            primaryPale = Color(0xFFE67326).copy(alpha = 0.10f),
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

val Surface0 = Color(0xFF000000) // page
val Surface1 = Color(0xFF1C1C1E) // resting card
val Surface2 = Color(0xFF2C2C2E) // raised
val Surface3 = Color(0xFF3A3A3C) // highest
val BorderHairline = Color.White.copy(alpha = 0.14f)
val BorderStrong = Color.White.copy(alpha = 0.36f)

// ---------------------------------------------------------------------------
// Platform background colors (port of PlatformCompat.swift)
// ---------------------------------------------------------------------------

// platformSecondaryGroupedBackground -> surface1, platformTertiaryGroupedBackground
// -> surface2 on the Swift side (PlatformCompat.swift) — "Secondary"/"Tertiary" name
// UIKit's own grouped-background tiers, not ramp step numbers.
val WindowBackground = Surface0
val SecondaryGroupedBg = Surface1
val TertiaryGroupedBg = Surface2
val SeparatorColor = Color(0xFF333338)

// Standard card
val CardBackground = Surface1
val CardBorder = BorderHairline

// OLED variants (toggled by user preference) — same ramp; page/card no longer invert.
val OledCardBackground = Surface1
val OledCardBorder = BorderHairline

// Console / dashboard — matches platformConsoleHeaderBackground -> surface2.
val ConsoleHeaderBg = Surface2

// Text colors
val PrimaryText = Color.White
val SecondaryText = Color.White.copy(alpha = 0.60f)
val TertiaryText = Color.White.copy(alpha = 0.40f)
val PlaceholderText = Color.White.copy(alpha = 0.25f)

// Status colors
val SuccessGreen = Color(0xFF34C759)
val WarningYellow = Color(0xFFFFCC00)
val ErrorRed = Color(0xFFFF3B30)
val InfoBlue = Color(0xFF007AFF)

// Engagement action colors: iOS's system red / green / orange in dark mode,
// which is all the app has (the light-mode values read dull on black).
val LikeRed = Color(0xFFFF453A)
val RepostGreen = Color(0xFF30D158)
val ZapOrange = Color(0xFFFF9F0A)

// Wizard accent (setup flow)
val WizardOrange = Color(0xFFF59E0B)
val WizardOrangeDark = Color(0xFFEA580C)
