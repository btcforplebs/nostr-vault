package com.nostrvault.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color

/**
 * CompositionLocal providing the current NostrVaultColorScheme.
 * Access via `LocalNostrVaultColors.current` in any composable.
 */
val LocalNostrVaultColors = staticCompositionLocalOf {
    AppTheme.DEFAULT.colors
}

/**
 * CompositionLocal providing the current AppTheme enum value.
 * Useful for checking which theme is active.
 */
val LocalAppTheme = staticCompositionLocalOf { AppTheme.DEFAULT }

/**
 * CompositionLocal for the user's text size scale preference.
 * Defaults to 1.0 (no scaling).
 */
val LocalTextSizeScale = staticCompositionLocalOf { 1.0f }

/**
 * CompositionLocal for OLED mode preference.
 * When true, card backgrounds use deeper blacks.
 */
val LocalOledMode = staticCompositionLocalOf { false }

/**
 * CompositionLocal for Zaps Only mode preference.
 * When true, likes/reactions are removed from the UI entirely and zaps
 * become the primary engagement + notification signal.
 */
val LocalZapsOnlyMode = staticCompositionLocalOf { false }

/**
 * Master theme composable for Nostr Vault.
 *
 * The app is permanently dark-themed (no light mode), matching iOS.
 * All 6 color themes are supported via [appTheme].
 */
@Composable
fun NostrVaultTheme(
    appTheme: AppTheme = AppTheme.DEFAULT,
    textSizeScale: Float = 1.0f,
    oledMode: Boolean = false,
    zapsOnlyMode: Boolean = false,
    content: @Composable () -> Unit,
) {
    val colors = appTheme.colors

    // Map our theme colors to Material 3 color slots
    val materialColors = darkColorScheme(
        primary = colors.primary,
        onPrimary = Color.White,
        primaryContainer = colors.primaryDark,
        onPrimaryContainer = Color.White,
        secondary = colors.primaryLight,
        onSecondary = Color.White,
        secondaryContainer = colors.primaryPale,
        onSecondaryContainer = colors.primary,
        tertiary = colors.primaryLight,
        onTertiary = Color.White,
        background = WindowBackground,
        onBackground = Color.White,
        surface = if (oledMode) OledCardBackground else CardBackground,
        onSurface = Color.White,
        surfaceVariant = SecondaryGroupedBg,
        onSurfaceVariant = SecondaryText,
        outline = SeparatorColor,
        outlineVariant = if (oledMode) OledCardBorder else CardBorder,
        error = ErrorRed,
        onError = Color.White,
    )

    val typography = nostrVaultTypography(scale = textSizeScale)

    CompositionLocalProvider(
        LocalNostrVaultColors provides colors,
        LocalAppTheme provides appTheme,
        LocalTextSizeScale provides textSizeScale,
        LocalOledMode provides oledMode,
        LocalZapsOnlyMode provides zapsOnlyMode,
    ) {
        MaterialTheme(
            colorScheme = materialColors,
            typography = typography,
            content = content,
        )
    }
}

/**
 * Convenience accessor for the current theme's color scheme.
 * Usage: `NostrVaultTheme.colors.primary`
 */
object NostrVaultTheme {
    val colors: NostrVaultColorScheme
        @Composable
        @ReadOnlyComposable
        get() = LocalNostrVaultColors.current
}
