package com.nostrvault.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/**
 * The app's type ramp, a port of the semantic styles in Theming.swift.
 *
 * Unscaled, deliberately. The user's Text Size preference is applied once, by
 * [NostrVaultTheme] overriding the ambient Density's `fontScale`, which reaches
 * every `sp` in the tree including these. A `scale` parameter here would scale a
 * second time.
 *
 * Installed as `MaterialTheme(typography = …)` but not yet read by call sites:
 * `MaterialTheme.typography` appears nowhere in the `ui/` tree and ~560 places
 * still pass `fontSize` literals. Migrating them onto these slots is real work
 * and a visible restyle — several sizes in use (14, 10, 18) have no slot — so it
 * is a separate task from making the setting work.
 *
 * Maps iOS semantic font styles to Material 3 Typography slots:
 *   displayLarge  = appLargeTitle (34sp)
 *   headlineLarge = appTitle      (28sp)
 *   headlineMedium = appTitle2    (22sp)
 *   headlineSmall = appTitle3     (20sp)
 *   titleLarge    = appHeadline   (17sp, semibold)
 *   titleMedium   = appBody       (17sp)
 *   titleSmall    = appCallout    (16sp)
 *   bodyLarge     = appSubheadline(15sp)
 *   bodyMedium    = appFootnote   (13sp)
 *   bodySmall     = appCaption    (12sp)
 *   labelSmall    = appCaption2   (11sp)
 */
fun nostrVaultTypography(): Typography = Typography(
    displayLarge = TextStyle(
        fontSize = 34.sp,
        fontWeight = FontWeight.Normal,
        lineHeight = 41.sp,
    ),
    headlineLarge = TextStyle(
        fontSize = 28.sp,
        fontWeight = FontWeight.Bold,
        lineHeight = 34.sp,
    ),
    headlineMedium = TextStyle(
        fontSize = 22.sp,
        fontWeight = FontWeight.Bold,
        lineHeight = 28.sp,
    ),
    headlineSmall = TextStyle(
        fontSize = 20.sp,
        fontWeight = FontWeight.Normal,
        lineHeight = 25.sp,
    ),
    titleLarge = TextStyle(
        fontSize = 17.sp,
        fontWeight = FontWeight.SemiBold,
        lineHeight = 22.sp,
    ),
    titleMedium = TextStyle(
        fontSize = 17.sp,
        fontWeight = FontWeight.Normal,
        lineHeight = 22.sp,
    ),
    titleSmall = TextStyle(
        fontSize = 16.sp,
        fontWeight = FontWeight.Normal,
        lineHeight = 21.sp,
    ),
    bodyLarge = TextStyle(
        fontSize = 15.sp,
        fontWeight = FontWeight.Normal,
        lineHeight = 20.sp,
    ),
    bodyMedium = TextStyle(
        fontSize = 13.sp,
        fontWeight = FontWeight.Normal,
        lineHeight = 18.sp,
    ),
    bodySmall = TextStyle(
        fontSize = 12.sp,
        fontWeight = FontWeight.Normal,
        lineHeight = 16.sp,
    ),
    labelSmall = TextStyle(
        fontSize = 11.sp,
        fontWeight = FontWeight.Normal,
        lineHeight = 13.sp,
    ),
)

/** Monospace variant for stats, amounts, hex strings, and code blocks. */
fun monoTextStyle(): TextStyle = TextStyle(
    fontFamily = FontFamily.Monospace,
    fontSize = 14.sp,
    fontWeight = FontWeight.Normal,
    lineHeight = 18.sp,
)
