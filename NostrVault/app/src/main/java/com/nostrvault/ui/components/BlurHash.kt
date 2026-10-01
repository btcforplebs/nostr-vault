package com.nostrvault.ui.components

import android.graphics.Bitmap
import android.util.LruCache
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.pow
import kotlin.math.withSign

/**
 * Decodes a BlurHash (https://blurha.sh), the blurred preview a NIP-92 `imeta`
 * tag can carry, into a small bitmap the feed stretches over a photo's box
 * until the photo itself arrives. Mirrors iOS `BlurHashDecoder`.
 */
internal object BlurHash {
    /**
     * Output is always 32x32: a blurhash has at most 9x9 components, so more
     * pixels add nothing once it is stretched to the card.
     */
    private const val SIDE = 32

    private val cache = LruCache<String, Bitmap>(200)

    /** The preview for [hash], decoded once per process; null if it is malformed. */
    fun bitmap(hash: String?): Bitmap? {
        if (hash.isNullOrEmpty()) return null
        cache.get(hash)?.let { return it }
        val pixels = decode(hash) ?: return null
        val bitmap = Bitmap.createBitmap(pixels, SIDE, SIDE, Bitmap.Config.ARGB_8888)
        cache.put(hash, bitmap)
        return bitmap
    }

    private const val ALPHABET =
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~"

    private fun decode83(s: String, from: Int, len: Int): Int? {
        var value = 0
        for (i in from until from + len) {
            val d = ALPHABET.indexOf(s[i])
            if (d < 0) return null
            value = value * 83 + d
        }
        return value
    }

    private fun sRGBToLinear(v: Int): Float {
        val x = v / 255f
        return if (x <= 0.04045f) x / 12.92f else ((x + 0.055f) / 1.055f).pow(2.4f)
    }

    private fun linearToSRGB(v: Float): Int {
        val x = v.coerceIn(0f, 1f)
        val s = if (x <= 0.0031308f) x * 12.92f else 1.055f * x.pow(1 / 2.4f) - 0.055f
        return (s * 255 + 0.5f).toInt().coerceIn(0, 255)
    }

    private fun signPow(v: Float, e: Float): Float = abs(v).pow(e).withSign(v)

    /** ARGB pixels, row-major, [SIDE] x [SIDE]; null if [hash] is malformed. */
    internal fun decode(hash: String): IntArray? {
        if (hash.length < 6) return null
        val sizeFlag = decode83(hash, 0, 1) ?: return null
        val nx = sizeFlag % 9 + 1
        val ny = sizeFlag / 9 + 1
        if (hash.length != 4 + 2 * nx * ny) return null
        val maxAC = ((decode83(hash, 1, 1) ?: return null) + 1) / 166f

        val colors = Array(nx * ny) { FloatArray(3) }
        val dc = decode83(hash, 2, 4) ?: return null
        colors[0][0] = sRGBToLinear(dc shr 16)
        colors[0][1] = sRGBToLinear((dc shr 8) and 255)
        colors[0][2] = sRGBToLinear(dc and 255)
        for (i in 1 until nx * ny) {
            val ac = decode83(hash, 4 + i * 2, 2) ?: return null
            colors[i][0] = signPow((ac / (19 * 19) - 9) / 9f, 2f) * maxAC
            colors[i][1] = signPow(((ac / 19) % 19 - 9) / 9f, 2f) * maxAC
            colors[i][2] = signPow((ac % 19 - 9) / 9f, 2f) * maxAC
        }

        // Basis cosines are separable: precompute each axis once.
        val n = SIDE
        val cosX = Array(nx) { i -> FloatArray(n) { x -> cos(Math.PI * x * i / n).toFloat() } }
        val cosY = Array(ny) { j -> FloatArray(n) { y -> cos(Math.PI * y * j / n).toFloat() } }
        val pixels = IntArray(n * n)
        for (y in 0 until n) {
            for (x in 0 until n) {
                var r = 0f; var g = 0f; var b = 0f
                for (j in 0 until ny) {
                    val cy = cosY[j][y]
                    for (i in 0 until nx) {
                        val basis = cosX[i][x] * cy
                        val c = colors[i + j * nx]
                        r += c[0] * basis; g += c[1] * basis; b += c[2] * basis
                    }
                }
                pixels[y * n + x] = (0xFF shl 24) or
                    (linearToSRGB(r) shl 16) or (linearToSRGB(g) shl 8) or linearToSRGB(b)
            }
        }
        return pixels
    }
}
