package com.nostrvault.ui.theme

import androidx.compose.ui.graphics.Color
import kotlin.math.cbrt
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt

/**
 * Settings > Appearance > Accent: the app's orange or one of eight ready-made
 * colours (PLANS/NV_LIGHT_MODE_AND_CUSTOM_COLORS.md; the colour wheel comes
 * later on Android). Twin of AccentPalette.swift and web-vault/src/net/accent.js:
 *
 * - Dark shows the colour as picked, lifted only if it fails 4.5:1 on a card.
 * - Light deepens it in OKLab until it reads as text on white (4.5:1).
 * - A label on an accent fill is white whenever white reads (3:1, a bold
 *   label), otherwise black, so yellow, teal and green get black labels.
 *
 * Saved as HavenConfig.themeColor: "orange" (the default) or "#rrggbb".
 */
object AccentPalette {
    const val DEFAULT_HEX = "#e67326"

    data class Preset(val hex: String, val name: String)

    /** The ready-made row, orange first. Apple's system colours, so each sits well on black. */
    val presets = listOf(
        Preset("#e67326", "Orange"), Preset("#ffd60a", "Yellow"), Preset("#30d158", "Green"),
        Preset("#40c8e0", "Teal"), Preset("#0a84ff", "Blue"), Preset("#5e5ce6", "Indigo"),
        Preset("#bf5af2", "Purple"), Preset("#ff375f", "Pink"),
    )

    /** One mode's accent ramp plus the label colour on it. */
    data class Ramp(val scheme: NostrVaultColorScheme, val onAccent: Color)

    fun normalize(value: String): String? {
        val v = value.trim().lowercase()
        return if (Regex("^#[0-9a-f]{6}$").matches(v)) v else null
    }

    /** The saved setting as "#rrggbb"; anything else is the default orange. */
    fun hex(setting: String): String = normalize(setting) ?: DEFAULT_HEX

    /** What themeColor should hold for a pick: the default stays "orange". */
    fun setting(hex: String): String {
        val pick = normalize(hex) ?: DEFAULT_HEX
        return if (pick == DEFAULT_HEX) AppTheme.DEFAULT.key else pick
    }

    fun swatch(hex: String): Color = color(rgb(normalize(hex) ?: DEFAULT_HEX))

    /** True when light mode has to deepen the colour to make it read. */
    fun shiftsInLight(hex: String): Boolean = contrast(rgb(normalize(hex) ?: DEFAULT_HEX), WHITE) < 3.0

    private val cache = HashMap<Pair<String, Boolean>, Ramp>()

    fun ramp(setting: String, light: Boolean): Ramp {
        val pick = hex(setting)
        return synchronized(cache) { cache.getOrPut(pick to light) { make(pick, light) } }
    }

    private fun make(pick: String, light: Boolean): Ramp {
        if (pick == DEFAULT_HEX) {
            // The orange keeps its hand-tuned ramp exactly.
            val t = AppTheme.DEFAULT
            return Ramp(if (light) t.lightColors else t.colors, Color.White)
        }
        val c = rgb(pick)
        val primary: Rgb
        val primaryLight: Rgb
        val primaryDark: Rgb
        if (light) {
            primary = readable(c, WHITE, 4.5, -1.0)
            primaryLight = readable(c, WHITE, 3.0, -1.0)
            primaryDark = shade(primary, -0.1)
        } else {
            primary = readable(c, CARD_DARK, 4.5, 1.0)
            primaryLight = shade(primary, 0.08)
            primaryDark = shade(primary, -0.12)
        }
        return Ramp(
            NostrVaultColorScheme(
                primary = color(primary),
                primaryLight = color(primaryLight),
                primaryDark = color(primaryDark),
                primaryPale = color(primary).copy(alpha = 0.10f),
            ),
            labelOn(primary),
        )
    }

    // ---- colour maths (port of net/accent.js); channels 0..255 ----

    private data class Rgb(val r: Double, val g: Double, val b: Double)

    private val WHITE = Rgb(255.0, 255.0, 255.0)
    private val CARD_DARK = Rgb(28.0, 28.0, 30.0)

    private fun rgb(hex: String): Rgb {
        val v = hex.drop(1).toLong(16)
        return Rgb(((v shr 16) and 0xFF).toDouble(), ((v shr 8) and 0xFF).toDouble(), (v and 0xFF).toDouble())
    }

    private fun color(c: Rgb) = Color(c.r.toInt(), c.g.toInt(), c.b.toInt())

    private fun lin(c: Double): Double { val x = c / 255; return if (x <= 0.04045) x / 12.92 else ((x + 0.055) / 1.055).pow(2.4) }
    private fun unlin(c: Double): Double = 255 * (if (c <= 0.0031308) 12.92 * c else 1.055 * c.pow(1 / 2.4) - 0.055)

    private fun luminance(c: Rgb) = 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)

    private fun contrast(a: Rgb, b: Rgb): Double {
        val x = luminance(a); val y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    // OKLab (Björn Ottosson): changing only L keeps the hue and how colourful it looks.
    private fun toLab(c: Rgb): DoubleArray {
        val r = lin(c.r); val g = lin(c.g); val b = lin(c.b)
        val l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        val m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        val s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return doubleArrayOf(
            0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s,
        )
    }

    private fun fromLab(lL: Double, a: Double, b: Double): Rgb {
        val l = (lL + 0.3963377774 * a + 0.2158037573 * b).pow(3)
        val m = (lL - 0.1055613458 * a - 0.0638541728 * b).pow(3)
        val s = (lL - 0.0894841775 * a - 1.291485548 * b).pow(3)
        fun ch(v: Double) = unlin(min(1.0, max(0.0, v))).roundToInt().toDouble()
        return Rgb(
            ch(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
            ch(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
            ch(-0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s),
        )
    }

    /** The colour moved lighter (dir 1) or darker (-1) in small steps until it reads at [minRatio] on [bg]. */
    private fun readable(c: Rgb, bg: Rgb, minRatio: Double, dir: Double): Rgb {
        if (contrast(c, bg) >= minRatio) return c
        val lab = toLab(c)
        for (i in 1..100) {
            val next = fromLab(min(1.0, max(0.0, lab[0] + dir * i * 0.01)), lab[1], lab[2])
            if (contrast(next, bg) >= minRatio) return next
        }
        return if (dir < 0) Rgb(0.0, 0.0, 0.0) else WHITE
    }

    private fun shade(c: Rgb, dL: Double): Rgb {
        val lab = toLab(c)
        return fromLab(min(1.0, max(0.0, lab[0] + dL)), lab[1], lab[2])
    }

    /** White or black for a label on a fill of this colour: white whenever it reads as a bold label. */
    private fun labelOn(c: Rgb): Color = if (contrast(WHITE, c) >= 3.0) Color.White else Color.Black
}
