package com.nostrvault.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density

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
 *
 * **Do not multiply a font size by this.** [NostrVaultTheme] applies the user's
 * preference once, by overriding [androidx.compose.ui.platform.LocalDensity]'s
 * `fontScale`, which scales every `sp` in the tree. A call site that also
 * multiplies by this value would scale twice. It is exposed for code that needs
 * to *read* the preference — to decide a layout, not a size.
 */
val LocalTextSizeScale = staticCompositionLocalOf { 1.0f }

/**
 * The `fontScale` to hand [androidx.compose.ui.platform.LocalDensity] so the
 * user's Text Size preference reaches every `sp` in the app.
 *
 * Multiplies rather than replaces: the system accessibility font scale is a
 * separate setting the user also chose, and dropping it would make this control
 * silently override the OS one.
 *
 * Clamped, because this arrives from persisted config rather than from the
 * slider that produced it. A zero or negative scale renders every string in the
 * app at zero height, which looks exactly like a blank screen.
 */
fun scaledFontScale(systemFontScale: Float, userScale: Float): Float {
    val safeSystem = if (systemFontScale.isFinite() && systemFontScale > 0f) systemFontScale else 1f
    val safeUser = if (userScale.isFinite()) userScale.coerceIn(MIN_TEXT_SCALE, MAX_TEXT_SCALE) else 1f
    return safeSystem * safeUser
}

/** Widest the Text Size slider goes is 0.8–1.6; these bound a corrupt config, not the UI. */
const val MIN_TEXT_SCALE = 0.5f
const val MAX_TEXT_SCALE = 2.0f

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
        background = Surface0,
        onBackground = Color.White,
        surface = Surface1,
        onSurface = Color.White,
        surfaceVariant = Surface2,
        onSurfaceVariant = SecondaryText,
        outline = SeparatorColor,
        outlineVariant = BorderHairline,
        error = ErrorRed,
        onError = Color.White,
    )

    // The ramp is installed unscaled. Scaling lives in exactly one place — the
    // density override below — because two mechanisms would multiply: a slot that
    // had already scaled itself would then be scaled again by the density.
    val typography = nostrVaultTypography()

    // This is what makes the Text Size setting do anything.
    //
    // The ramp was being built from the preference and installed as
    // `MaterialTheme(typography = …)`, and then nothing read it:
    // `MaterialTheme.typography` is referenced nowhere in the `ui/` tree, there
    // is no `ProvideTextStyle`, and ~560 call sites pass `fontSize = <n>.sp`
    // directly. Compose does not apply Typography slots on its own, so moving
    // the slider changed a value no `Text` ever consulted.
    //
    // `sp` is resolved to pixels through the ambient Density's `fontScale`, so
    // overriding it here reaches every `sp` in the tree at once — the hardcoded
    // literals, the unstyled `Text`s on the Compose default, and the ramp if and
    // when call sites migrate onto it. `dp` is untouched, so boxes keep their
    // sizes and text growing inside a fixed-height row shows up as clipping
    // rather than being silently absorbed. That is the honest failure mode and
    // it is where a working ramp actually breaks layout.
    val baseDensity = LocalDensity.current
    val scaledDensity = remember(baseDensity, textSizeScale) {
        Density(
            density = baseDensity.density,
            fontScale = scaledFontScale(baseDensity.fontScale, textSizeScale),
        )
    }

    CompositionLocalProvider(
        LocalNostrVaultColors provides colors,
        LocalAppTheme provides appTheme,
        LocalTextSizeScale provides textSizeScale,
        LocalOledMode provides oledMode,
        LocalZapsOnlyMode provides zapsOnlyMode,
        LocalDensity provides scaledDensity,
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
