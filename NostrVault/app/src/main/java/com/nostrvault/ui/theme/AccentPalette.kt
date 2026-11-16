package com.nostrvault.ui.theme

import androidx.compose.ui.graphics.Color
import kotlin.math.atan2
import kotlin.math.cbrt
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * Settings > Appearance > Accent: the app's orange or one of eight ready-made
 * colours or any colour from the wheel (PLANS/NV_LIGHT_MODE_AND_CUSTOM_COLORS.md).
 * Twin of AccentPalette.swift and web-vault/src/net/accent.js:
 *
 * - Dark is neon ([neon]): the same hue at (nearly) the most chroma sRGB
 *   allows, made lighter only until it reads 4.5:1 on a card. Fills and text.
 * - Light fills (buttons, rings, borders) use the colour exactly as picked.
 *   Only accent text ([NostrVaultColorScheme.primaryText]: #tags, links) is
 *   darkened, and only under 3.5:1 on white (gold, green, teal, orange),
 *   until it reads at 4.5:1.
 * - A label on an accent fill is white whenever white reads (3:1, a bold
 *   label), otherwise black, so yellow, teal and green get black labels.
 *
 * Saved as HavenConfig.themeColor: "orange" (the default) or "#rrggbb".
 */
object AccentPalette {
    const val DEFAULT_HEX = "#e67326"

    data class Preset(val hex: String, val name: String)

    /**
     * The ready-made row, orange first: three anchors (the app's orange, Nostr
     * purple from the Nostr logo, Android green) and the colours around them.
     * Light shows these exactly; Dark shows [neon] of each.
     */
    val presets = listOf(
        Preset("#e67326", "Orange"), Preset("#ffb800", "Gold"), Preset("#3ddc84", "Green"),
        Preset("#00c2b8", "Teal"), Preset("#2e7dff", "Blue"), Preset("#662482", "Nostr purple"),
        Preset("#ff2d87", "Pink"), Preset("#a8071a", "Blood red"),
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

    /** True when [hex] is one of the ready-made row. */
    fun isPreset(hex: String): Boolean = presets.any { it.hex == normalize(hex) }

    fun swatch(hex: String): Color = color(rgb(normalize(hex) ?: DEFAULT_HEX))

    /** Light mode's page: the warm off-white with [PAPER_TINT] of the picked accent mixed in. */
    const val PAPER = "#f6f1eb"
    const val PAPER_TINT = 0.05

    private val paperCache = HashMap<String, Color>()

    /** Light's page colour for this accent setting (twin of paper() in net/accent.js). */
    fun paper(setting: String): Color {
        val pick = hex(setting)
        return synchronized(paperCache) {
            paperCache.getOrPut(pick) {
                val a = rgb(PAPER); val b = rgb(pick)
                fun m(x: Double, y: Double) = Math.round(x + (y - x) * PAPER_TINT).toDouble()
                color(Rgb(m(a.r, b.r), m(a.g, b.g), m(a.b, b.b)))
            }
        }
    }

    /** True when light mode darkens the colour's text to make it read (its fills stay exact). */
    fun shiftsInLight(hex: String): Boolean = contrast(rgb(normalize(hex) ?: DEFAULT_HEX), WHITE) < LIGHT_TEXT_KEEP

    /** Light keeps the exact colour as text at or above this on white. */
    private const val LIGHT_TEXT_KEEP = 3.5

    /** Dark mode's neon of a colour, as "#rrggbb" (twin of neon() in net/accent.js). */
    fun neonHex(hex: String): String = hexOf(neon(rgb(normalize(hex) ?: DEFAULT_HEX)))

    private val cache = HashMap<Pair<String, Boolean>, Ramp>()

    fun ramp(setting: String, light: Boolean): Ramp {
        val pick = hex(setting)
        return synchronized(cache) { cache.getOrPut(pick to light) { make(pick, light) } }
    }

    private fun make(pick: String, light: Boolean): Ramp {
        val c = rgb(pick)
        val fill: Rgb
        val text: Rgb
        val fillLight: Rgb
        val fillDark: Rgb
        if (light) {
            fill = c
            text = if (contrast(c, WHITE) >= LIGHT_TEXT_KEEP) c else readable(c, WHITE, 4.5, -1.0)
            // The fill's light end: a touch lighter, unless that would fade a white label under 3:1.
            val lift = shade(c, 0.08)
            fillLight = if (labelOn(c) == Color.Black || contrast(WHITE, lift) >= 3.0) lift else c
            fillDark = shade(c, -0.1)
        } else {
            fill = neon(c)
            text = fill
            fillLight = shade(fill, 0.08)
            fillDark = shade(fill, -0.12)
        }
        return Ramp(
            NostrVaultColorScheme(
                primary = color(fill),
                primaryLight = color(fillLight),
                primaryDark = color(fillDark),
                primaryPale = color(fill).copy(alpha = 0.10f),
                primaryText = color(text),
            ),
            labelOn(fill),
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

    private fun hexOf(c: Rgb) = "#%02x%02x%02x".format(c.r.toInt(), c.g.toInt(), c.b.toInt())

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

    /** OKLab to linear sRGB, unclamped (out of 0..1 = outside sRGB). */
    private fun labLinear(lL: Double, a: Double, b: Double): DoubleArray {
        val l = (lL + 0.3963377774 * a + 0.2158037573 * b).pow(3)
        val m = (lL - 0.1055613458 * a - 0.0638541728 * b).pow(3)
        val s = (lL - 0.0894841775 * a - 1.291485548 * b).pow(3)
        return doubleArrayOf(
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s,
        )
    }

    private fun fromLab(lL: Double, a: Double, b: Double): Rgb {
        val v = labLinear(lL, a, b)
        fun ch(x: Double) = unlin(min(1.0, max(0.0, x))).roundToInt().toDouble()
        return Rgb(ch(v[0]), ch(v[1]), ch(v[2]))
    }

    /** The most chroma sRGB holds at this OKLCH lightness and hue. */
    private fun maxChroma(lL: Double, h: Double): Double {
        var lo = 0.0
        var hi = 0.4
        repeat(30) {
            val mid = (lo + hi) / 2
            if (labLinear(lL, mid * cos(h), mid * sin(h)).all { it >= -1e-4 && it <= 1 + 1e-4 }) lo = mid else hi = mid
        }
        return lo
    }

    /**
     * Neon: the colour's hue at (nearly) the most chroma sRGB allows, at the
     * darkest lightness from max(its own, 0.55) up that reads 4.5:1 on the dark
     * card. Greys have no hue to push, so they only get lighter.
     */
    private fun neon(c: Rgb): Rgb {
        val lab = toLab(c)
        val c0 = hypot(lab[1], lab[2])
        val h = atan2(lab[2], lab[1])
        if (c0 < 0.03) return readable(c, CARD_DARK, 4.5, 1.0)
        val start = max(lab[0], 0.55)
        var i = 0
        while (start + i * 0.005 <= 0.95) {
            val lL = start + i * 0.005
            val top = maxChroma(lL, h)
            val ch = min(top, max(c0, top * 0.97))
            val next = fromLab(lL, ch * cos(h), ch * sin(h))
            if (contrast(next, CARD_DARK) >= 4.5) return next
            i++
        }
        val top = maxChroma(0.95, h)
        return fromLab(0.95, top * cos(h), top * sin(h))
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
