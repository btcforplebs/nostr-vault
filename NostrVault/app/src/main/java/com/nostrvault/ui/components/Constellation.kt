package com.nostrvault.ui.components

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * A face for an account with no picture: a small constellation drawn from the pubkey (Logen 2026-11-21).
 * Port of web-vault/src/components/constellation.js, to RESEARCH/NV_CONSTELLATION_AVATAR_SPEC.md (v2). The unit test
 * checks it against web-vault/test/fixtures/CONSTELLATION_VECTORS.json. Change one, change all three and the vectors.
 *
 * Everything is in a 100x100 box, rounded to 2 decimals ([r2]) before it is used again.
 */
object Constellation {

    data class Star(val x: Double, val y: Double, val r: Double)
    data class Dust(val x: Double, val y: Double, val r: Double)
    data class Cloud(val x: Double, val y: Double, val radius: Double, val color: Int, val alpha: Double)

    /** Colours are 0xRRGGBB. */
    data class Sky(
        val hue: Int,
        val stars: List<Star>,
        val links: List<Pair<Int, Int>>,
        val you: Int,
        val dust: List<Dust>,
        val clouds: List<Cloud>,
        val skyInner: Int,
        val skyOuter: Int,
        val line: Int,
        val star: Int,
        val glow: Int,
    )

    fun r2(x: Double): Double = floor(x * 100 + 0.5) / 100

    /** FNV-1a, 32 bit, over the bytes (as an unsigned value in an Int). */
    fun fnv1a(bytes: ByteArray): Int {
        var h = 0x811c9dc5.toInt()
        for (b in bytes) { h = (h xor (b.toInt() and 0xff)) * 0x01000193 }
        return h
    }

    /** mulberry32: each call is the next number in [0, 1). */
    fun mulberry32(seed: Int): () -> Double {
        var s = seed
        return {
            s += 0x6D2B79F5
            var t = s
            t = (t xor (t ushr 15)) * (t or 1)
            t = t xor (t + (t xor (t ushr 7)) * (t or 61))
            (t xor (t ushr 14)).toUInt().toDouble() / 4294967296.0
        }
    }

    /** HSL (h 0-359, s and l 0-100) -> 0xRRGGBB, each channel rounded half up (the CSS formula). */
    fun hsl(h: Int, sPct: Int, lPct: Int): Int {
        val s = sPct / 100.0
        val l = lPct / 100.0
        val a = s * min(l, 1 - l)
        fun f(n: Int): Int {
            val k = (n + h / 30.0) % 12
            val v = l - a * max(-1.0, min(min(k - 3, 9 - k), 1.0))
            return floor(v * 255 + 0.5).toInt()
        }
        return (f(0) shl 16) or (f(8) shl 8) or f(4)
    }

    fun hexBytes(hex: String): ByteArray = ByteArray(hex.length / 2) { hex.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    private val HEX64 = Regex("^[0-9a-f]{64}$")
    fun isPubkey(hex: String): Boolean = HEX64.matches(hex)

    private const val MIN_GAP = 12.0
    private const val SKY = 44.0
    private const val MAX_TRIES = 400
    private const val LINK_MAX = 30.0
    private const val MAX_DEGREE = 4

    /** The drawing as numbers (the spec's steps 1-9). [hex]: 64 lowercase hex chars. */
    fun of(hex: String): Sky {
        val rnd = mulberry32(fnv1a(hexBytes(hex)))
        // 2. hue, 3. how many stars
        val hue = floor(rnd() * 360).toInt()
        val n = 9 + floor(rnd() * 5).toInt()
        // 4. stars spread over the whole sky, never closer than MIN_GAP
        val pts = ArrayList<Pair<Double, Double>>()
        var t = 0
        while (t < MAX_TRIES && pts.size < n) {
            val a = rnd() * 2 * PI
            val r = SKY * sqrt(rnd())
            val x = r2(50 + r * cos(a))
            val y = r2(50 + r * sin(a))
            if (pts.all { (sx, sy) -> (sx - x) * (sx - x) + (sy - y) * (sy - y) >= MIN_GAP * MIN_GAP }) pts.add(x to y)
            t++
        }
        // 5. sizes
        val stars = pts.map { (x, y) -> Star(x, y, r2(2.2 + floor(rnd() * 4) * 0.4)) }
        val count = stars.size
        // 6. links: the shortest tree that reaches every star, then the shortest other links under LINK_MAX
        fun d2(i: Int, j: Int): Double {
            val dx = stars[i].x - stars[j].x
            val dy = stars[i].y - stars[j].y
            return r2(dx * dx + dy * dy)
        }
        val links = ArrayList<Pair<Int, Int>>()
        val degree = IntArray(count)
        fun add(i: Int, j: Int) { links.add(min(i, j) to max(i, j)); degree[i]++; degree[j]++ }
        val inTree = BooleanArray(count).also { if (count > 0) it[0] = true }
        var treeSize = if (count > 0) 1 else 0
        while (treeSize < count) {
            var bi = -1; var bj = -1; var bd = 0.0
            for (i in 0 until count) {
                if (!inTree[i]) continue
                for (j in 0 until count) {
                    if (inTree[j]) continue
                    val d = d2(i, j)
                    if (bi < 0 || d < bd) { bi = i; bj = j; bd = d } // a tie keeps the pair found first
                }
            }
            add(bi, bj); inTree[bj] = true; treeSize++
        }
        val linked = links.toHashSet()
        data class Other(val i: Int, val j: Int, val d: Double)
        val others = ArrayList<Other>()
        for (i in 0 until count) for (j in i + 1 until count) if ((i to j) !in linked) others.add(Other(i, j, d2(i, j)))
        others.sortWith(compareBy<Other> { it.d }.thenBy { it.i }.thenBy { it.j })
        for (o in others) {
            if (links.size >= count - 1 + count / 2) break
            if (o.d >= LINK_MAX * LINK_MAX || degree[o.i] >= MAX_DEGREE || degree[o.j] >= MAX_DEGREE) continue
            add(o.i, o.j)
        }
        // 7. you: the star with the most links, then the one nearest the middle, then the lowest index
        fun mid(i: Int) = (stars[i].x - 50) * (stars[i].x - 50) + (stars[i].y - 50) * (stars[i].y - 50)
        var you = 0
        for (i in 1 until count) if (degree[i] > degree[you] || (degree[i] == degree[you] && mid(i) < mid(you))) you = i
        // 8. dust: 16 draws, kept only inside the circle (all three numbers are always drawn)
        val dust = ArrayList<Dust>()
        repeat(16) {
            val x = r2(6 + rnd() * 88)
            val y = r2(6 + rnd() * 88)
            val r = r2(0.5 + floor(rnd() * 3) * 0.25)
            if ((x - 50) * (x - 50) + (y - 50) * (y - 50) <= 48.0 * 48.0) dust.add(Dust(x, y, r))
        }
        // 9. two nebula clouds behind everything
        fun cloud(radius: Double, h: Int, s: Int, l: Int, alpha: Double): Cloud {
            val a = rnd() * 2 * PI
            val d = 10 + rnd() * 20
            return Cloud(r2(50 + d * cos(a)), r2(50 + d * sin(a)), radius, hsl(h, s, l), alpha)
        }
        val clouds = listOf(cloud(42.0, (hue + 50) % 360, 75, 50, 0.5), cloud(34.0, (hue + 320) % 360, 70, 45, 0.4))
        return Sky(
            hue = hue, stars = stars, links = links, you = you, dust = dust, clouds = clouds,
            skyInner = hsl(hue, 55, 24), skyOuter = hsl((hue + 30) % 360, 60, 8),
            line = hsl(hue, 85, 84), star = hsl(hue, 60, 96), glow = hsl(hue, 90, 85),
        )
    }
}
