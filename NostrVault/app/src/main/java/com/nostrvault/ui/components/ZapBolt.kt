package com.nostrvault.ui.components

import androidx.compose.ui.geometry.Offset
import kotlin.math.floor
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.random.Random

/**
 * The lightning bolt's shape and timing, ported number-for-number from iOS
 * `ZapBolt` (ZapFlightView.swift, #119) and kept apart from drawing so the
 * numbers can be read — and unit-tested — in one place.
 *
 * Shapes are stored in the line's own frame — [Point.along] from 0 at your
 * avatar to 1 at the button, [Point.side] in dp off that line — so the bolt
 * still joins the two ends if the feed scrolls mid-strike.
 */
object ZapBolt {
    data class Point(val along: Float, val side: Float)

    /**
     * A fork off the main channel: starts at one of its vertices and
     * crackles off to one side for a short way.
     */
    data class Branch(
        val fromIndex: Int,
        /** Relative to the fork point. */
        val points: List<Point>,
        /** 0..1, how far down the leader it appears. */
        val reach: Double,
    )

    /** Seconds the stepped leader takes to feel its way across. */
    const val LEADER_TIME = 0.26
    /** The return stroke: when the channel slams white and the zap lands. */
    const val STRIKE_AT = 0.30
    /** Brightness of each strobe after the strike, one per [STROBE_STEP]. */
    val STROBES = doubleArrayOf(1.0, 0.18, 0.95, 0.12, 0.75, 0.4, 0.2)
    const val STROBE_STEP = 0.045
    /** Seconds the screen keeps glowing after the strike. */
    const val GLOW_LIFE = 0.55
    /** The leader advances in this many jumps rather than sliding. */
    const val LEADER_STEPS = 7
    /** The leader re-jitters to the next channel shape this often. */
    const val LEADER_FLICKER = 0.03
    /** Rounds of midpoint displacement; the channel has 2^n + 1 vertices. */
    const val ROUNDS = 6
    const val VERTICES = (1 shl ROUNDS) + 1

    val TOTAL: Double get() = STRIKE_AT + max(STROBES.size * STROBE_STEP, GLOW_LIFE)

    /**
     * A jagged channel by midpoint displacement: split every segment, shove
     * the midpoint sideways, and halve the shove each round. Ends are pinned
     * to the avatar and the button. [lengthDp] is the straight-line distance.
     */
    fun channel(lengthDp: Float, random: Random = Random): List<Point> {
        var points = listOf(Point(0f, 0f), Point(1f, 0f))
        var spread = (lengthDp * 0.22f).coerceIn(36f, 95f)
        repeat(ROUNDS) {
            val next = ArrayList<Point>(points.size * 2)
            next.add(points[0])
            for (i in 1 until points.size) {
                val a = points[i - 1]
                val b = points[i]
                next.add(
                    Point(
                        along = (a.along + b.along) / 2 + random.nextFloat(-0.012f, 0.012f),
                        side = (a.side + b.side) / 2 + random.nextFloat(-spread, spread),
                    ),
                )
                next.add(b)
            }
            points = next
            spread *= 0.58f
        }
        return points
    }

    fun branches(lengthDp: Float, random: Random = Random): List<Branch> {
        val count = if (lengthDp > 260f) 3 else 2
        return List(count) {
            val from = random.nextInt(8, VERTICES - 16 + 1)
            val sign = if (random.nextBoolean()) 1f else -1f
            val reach = random.nextFloat(0.08f, 0.16f)
            val points = ArrayList<Point>(7)
            points.add(Point(0f, 0f))
            var side = 0f
            for (step in 1..6) {
                side += sign * random.nextFloat(6f, 16f)
                points.add(Point(reach * step / 6f, side + random.nextFloat(-5f, 5f)))
            }
            Branch(from, points, from.toDouble() / (VERTICES - 1))
        }
    }

    /**
     * Maps a stored point onto the screen for the current ends. [start] and
     * [end] are in px; [density] turns the stored dp offsets into px.
     */
    fun place(p: Point, start: Offset, end: Offset, density: Float): Offset {
        val dx = end.x - start.x
        val dy = end.y - start.y
        val length = max(hypot(dx, dy), 1f)
        val nx = -dy / length
        val ny = dx / length
        val side = p.side * density
        return Offset(start.x + dx * p.along + nx * side, start.y + dy * p.along + ny * side)
    }

    /** Places a branch so its first point sits on [base], a vertex of the drawn channel. */
    fun placeBranch(branch: Branch, base: Offset, start: Offset, end: Offset, density: Float): List<Offset> {
        val origin = place(Point(0f, 0f), start, end, density)
        return branch.points.map { p ->
            val at = place(p, start, end, density)
            Offset(base.x + at.x - origin.x, base.y + at.y - origin.y)
        }
    }

    /** What a strike shows [elapsed] seconds after launch. */
    data class Frame(
        /** 0..1 through the charge, while the avatar crackles; null after the strike. */
        val charge: Double?,
        /** How far along the stepped leader reaches; null once the stroke returns. */
        val leaderReach: Double?,
        /** Which channel shape the leader shows. */
        val leaderChannel: Int,
        /** Which strobe of the return stroke is lit; null outside the strobes. */
        val strobe: Int?,
        /** The instant the screen flashes white. */
        val flash: Boolean,
        /** 0..1 through the afterglow; null before the strike and after it fades. */
        val glow: Double?,
    ) {
        val strobeBrightness: Double get() = strobe?.let { STROBES[it] } ?: 0.0
    }

    fun frame(elapsed: Double): Frame {
        val e = max(elapsed, 0.0)
        if (e < STRIKE_AT) {
            val progress = min(e / LEADER_TIME, 1.0)
            val stepped = floor(progress * LEADER_STEPS) / LEADER_STEPS + 0.6 / LEADER_STEPS
            return Frame(
                charge = e / STRIKE_AT,
                leaderReach = stepped,
                leaderChannel = (e / LEADER_FLICKER).toInt() % STROBES.size,
                strobe = null,
                flash = false,
                glow = null,
            )
        }
        val since = e - STRIKE_AT
        val strobe = (since / STROBE_STEP).toInt().takeIf { it < STROBES.size }
        val glow = (since / GLOW_LIFE).takeIf { it < 1.0 }
        return Frame(
            charge = null,
            leaderReach = null,
            leaderChannel = 0,
            strobe = strobe,
            flash = strobe == 0,
            glow = glow,
        )
    }

    /**
     * How long after the custom-amount sheet confirmed the strike waits, so
     * it crosses a screen the sheet has cleared (iOS #126 waits 0.4 s).
     */
    const val SHEET_CLEAR_MS = 400L

    /** Milliseconds a strike launched at [nowMs] should still wait; 0 to go now. */
    fun sheetWaitMs(nowMs: Long, sheetConfirmedAtMs: Long): Long {
        if (sheetConfirmedAtMs == Long.MIN_VALUE || nowMs < sheetConfirmedAtMs) return 0
        return (sheetConfirmedAtMs + SHEET_CLEAR_MS - nowMs).coerceAtLeast(0)
    }

    /** The afterglow's brightness: a fast rise over the first tenth, then a long fall. */
    fun glowStrength(g: Double): Double = if (g < 0.1) g / 0.1 else 1 - (g - 0.1) / 0.9

    private fun Random.nextFloat(from: Float, until: Float): Float = from + nextFloat() * (until - from)
}
