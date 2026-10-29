package com.nostrvault.data.model

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * A kind 33331 3D object (SNO, DECK-0003 by arkin0x), read and checked as the
 * spec's §1.9 says: the whole payload or nothing, and when nothing, the rule
 * it broke. Ported from the spec's reference reader (decks/sno-reference.py),
 * whose rejection table [SnoObjectTest] repeats.
 *
 * Positions are kept as floats only for drawing: nothing here welds or
 * compares them, which §1.2 would require to happen on the integer lattice.
 */
class SnoObject(
    val name: String,
    val mode: Mode,
    /** x, y, z per vertex in model units, in the §2 frame (Y up, +Z toward the viewer). */
    val positions: FloatArray,
    /** One RGB colour per vertex, no alpha. */
    val vertexColors: IntArray,
    /** Three vertex indices per face. */
    val faces: IntArray,
    /** One RGB colour per face, or null when every face interpolates its vertices (§1.4a). */
    val faceColors: IntArray?,
    /** Where each placed part stands, x, y, z in model units. Drawn as placeholder cubes (§1.10). */
    val partOrigins: FloatArray,
) {
    enum class Mode { SOLID, POINTS, LINES }

    val vertexCount: Int get() = positions.size / 3
    val faceCount: Int get() = faces.size / 3

    sealed class Read {
        data class Ok(val obj: SnoObject) : Read()
        /** [reason] names the §1.9 rule, as the spec asks a reader to show (§4). */
        data class Rejected(val reason: String) : Read()
    }

    companion object {
        const val KIND = 33331
        private const val MAX_UNIT = 84
        private const val TICKS_PER_UNIT = 120
        private const val PART_REACH = 64 * 120
        private val HEX64 = Regex("[0-9a-f]{64}")
        private val ADDRESS = Regex("33331:[0-9a-f]{64}:.*", RegexOption.DOT_MATCHES_ALL)
        private val PALETTE_REF = Regex("(nevent1|naddr1)[023456789acdefghjklmnpqrstuvwxyz]{20,}")
        private val INT = Regex("-?\\d+")
        private val json = Json { isLenient = false }

        /** Reads an event's content. Never throws. */
        fun read(content: String): Read = try {
            Read.Ok(validate(json.parseToJsonElement(content)))
        } catch (e: SnoError) {
            Read.Rejected(e.message ?: "invalid")
        } catch (e: Exception) {
            Read.Rejected("not a JSON object")
        }

        private class SnoError(message: String) : Exception(message)

        private fun JsonElement?.int(): Long? {
            val p = this as? JsonPrimitive ?: return null
            if (p.isString || p is JsonNull || !INT.matches(p.content)) return null
            return p.content.toLongOrNull()
        }

        private fun JsonElement?.num(): Double? {
            val p = this as? JsonPrimitive ?: return null
            if (p.isString || p is JsonNull) return null
            if (p.content == "true" || p.content == "false") return null
            return p.content.toDoubleOrNull()
        }

        private fun validate(root: JsonElement): SnoObject {
            val o = root as? JsonObject ?: throw SnoError("rule 1: payload is not a JSON object")

            // 1. version; a `type` field is ignored (§1.1a).
            val v = o["v"].int()
            if (v != 1L && v != 2L) throw SnoError("rule 1: v must be 1 or 2")

            // 2. the three arrays, vertices parallel to colors
            val vertices = o["vertices"] as? JsonArray ?: throw SnoError("rule 2: vertices is not an array")
            val colors = o["colors"] as? JsonArray ?: throw SnoError("rule 2: colors is not an array")
            val faces = o["faces"] as? JsonArray ?: throw SnoError("rule 2: faces is not an array")
            if (vertices.size != colors.size) throw SnoError("rule 2: ${vertices.size} vertices but ${colors.size} colors")
            // 3. no bound on the counts (§1.8).

            // 4. mode
            val mode = when ((o["mode"] as? JsonPrimitive)?.takeIf { it.isString }?.content) {
                "solid" -> Mode.SOLID
                "points" -> Mode.POINTS
                "lines" -> Mode.LINES
                else -> throw SnoError("rule 4: mode must be solid, points or lines")
            }

            // 5. unit
            val unit = o["unit"].int()
            if (unit == null || unit !in 0..MAX_UNIT) throw SnoError("rule 5: unit must be an integer in 0..$MAX_UNIT")

            // 6. the vertex triples
            val n = vertices.size
            val whole = LongArray(n * 3)
            vertices.forEachIndexed { i, el ->
                val t = el as? JsonArray
                if (t == null || t.size != 3) throw SnoError("rule 6: a vertex is not three integers")
                for (a in 0..2) whole[i * 3 + a] = t[a].int() ?: throw SnoError("rule 6: a vertex is not three integers")
            }

            // 7. ticks
            val ticks = expandTicks(o["ticks"], n)

            // 8a. palette, then 8b the colours against it
            val palette = resolvePalette(o["palette"])
            val vertexColors = IntArray(n)
            if (v == 1L) {
                // §1.3: version 1 carries literal [r, g, b] in 0..1, clamped, never snapped.
                colors.forEachIndexed { i, el ->
                    val t = el as? JsonArray
                    val rgb = t?.takeIf { it.size == 3 }?.map { it.num() }
                    if (rgb == null || rgb.any { it == null }) throw SnoError("rule 8b: a v1 colour is not three numbers")
                    vertexColors[i] = rgbOf(rgb.map { (it!!.coerceIn(0.0, 1.0) * 255).toInt() })
                }
            } else {
                colors.forEachIndexed { i, el ->
                    val c = el.int()
                    if (c == null || c < 0 || c >= palette.size) {
                        throw SnoError("rule 8b: a colour index is not an integer in 0..${palette.size - 1}")
                    }
                    vertexColors[i] = palette[c.toInt()]
                }
            }

            // 8. faces
            val faceIdx = IntArray(faces.size * 3)
            faces.forEachIndexed { i, el ->
                val t = el as? JsonArray
                val ix = t?.takeIf { it.size == 3 }?.map { it.int() }
                if (ix == null || ix.any { it == null }) throw SnoError("rule 8: a face is not three integers")
                if (ix.any { it!! < 0 || it >= n }) throw SnoError("rule 8: a face indexes a vertex outside 0..${n - 1}")
                if (ix.toSet().size != 3) throw SnoError("rule 8: a face repeats a vertex")
                for (a in 0..2) faceIdx[i * 3 + a] = ix[a]!!.toInt()
            }

            // 8c. face colours
            val faceColors = if (o.containsKey("facecolors")) {
                expandFaceColors(o["facecolors"], faces.size, palette.size).let { idx ->
                    IntArray(idx.size) { palette[idx[it]] }
                }
            } else null

            // 9. extent is repaired, never validated; this reader fits the view to the data instead.

            // 10. standing on Earth
            if (o.containsKey("up")) {
                val up = o["up"] as? JsonPrimitive
                if (up == null || up.isString || (up.content != "true" && up.content != "false")) {
                    throw SnoError("rule 10: up, when present, must be a boolean")
                }
            }
            if (o.containsKey("spin")) {
                val spin = o["spin"].int()
                if (spin == null || spin !in 0..359) throw SnoError("rule 10: spin must be an integer in 0..359")
            }

            // 11. refs
            val refs = when (val r = o["refs"]) {
                null -> JsonArray(emptyList())
                is JsonArray -> r
                else -> throw SnoError("rule 11: refs is not an array")
            }
            for (r in refs) {
                val parts = (r as? JsonArray)?.map { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }
                if (parts == null || parts.size !in 2..3 || parts.any { it == null }) {
                    throw SnoError("rule 11: a refs entry is not a tag of two or three strings")
                }
                val ok = (parts[0] == "e" && HEX64.matches(parts[1]!!)) ||
                    (parts[0] == "a" && ADDRESS.matches(parts[1]!!))
                if (!ok) throw SnoError("rule 11: a refs entry is neither an e nor an a reference")
            }

            // 12. parts
            val parts = when (val p = o["parts"]) {
                null -> JsonArray(emptyList())
                is JsonArray -> p
                else -> throw SnoError("rule 12: parts is not an array")
            }
            val partOrigins = FloatArray(parts.size * 3)
            parts.forEachIndexed { i, el ->
                val p = (el as? JsonArray)?.map { it.int() }
                if (p == null || p.size != 8 || p.any { it == null }) throw SnoError("rule 12: a placement is not eight integers")
                if (p[0]!! !in 0 until refs.size) throw SnoError("rule 12: a placement names no refs entry")
                if ((1..3).any { p[it]!! !in -PART_REACH..PART_REACH }) throw SnoError("rule 12: a placement stands past the 64-unit bound")
                if ((4..6).any { p[it]!! !in 0..359 }) throw SnoError("rule 12: a turn is not whole degrees 0..359")
                for (a in 0..2) partOrigins[i * 3 + a] = p[1 + a]!! / TICKS_PER_UNIT.toFloat()
            }
            // 13. an object may be only the arrangement of others; 14-15 repair, never reject.

            // §2: version 1 negates Z on read.
            val positions = FloatArray(n * 3)
            for (i in 0 until n) for (a in 0..2) {
                val p = (whole[i * 3 + a] * TICKS_PER_UNIT + ticks[i * 3 + a]) / TICKS_PER_UNIT.toFloat()
                positions[i * 3 + a] = if (a == 2 && v == 1L) -p else p
            }
            if (v == 1L) for (i in 0 until parts.size) partOrigins[i * 3 + 2] = -partOrigins[i * 3 + 2]

            val name = ((o["name"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: "").take(64)
            return SnoObject(name, mode, positions, vertexColors, faceIdx, faceColors, partOrigins)
        }

        /** §1.2: run-length remainders, one triple per vertex. */
        private fun expandTicks(el: JsonElement?, count: Int): IntArray {
            val out = IntArray(count * 3)
            if (el == null) return out
            val arr = el as? JsonArray ?: throw SnoError("rule 7: ticks is not an array")
            var at = 0
            for (entry in arr) {
                val run = entry.int()
                if (run != null) {
                    if (run >= 0) throw SnoError("rule 7: a run-length entry must be negative")
                    if (at - run > count) throw SnoError("rule 7: ticks expand past $count vertices")
                    at += (-run).toInt()
                } else {
                    val t = (entry as? JsonArray)?.takeIf { it.size == 3 }
                        ?: throw SnoError("rule 7: a ticks entry is neither a triple nor a negative integer")
                    val c = t.map { it.int() }
                    if (c.any { it == null || it !in 0 until TICKS_PER_UNIT }) {
                        throw SnoError("rule 7: a tick component is not an integer in 0..119")
                    }
                    if (at >= count) throw SnoError("rule 7: ticks expand past $count vertices")
                    for (a in 0..2) out[at * 3 + a] = c[a]!!.toInt()
                    at++
                }
            }
            if (at != count) throw SnoError("rule 7: ticks expand to $at remainders for $count vertices")
            return out
        }

        /** §1.4a: run-length face colours, one palette index per face. */
        private fun expandFaceColors(el: JsonElement?, count: Int, paletteSize: Int): IntArray {
            val arr = el as? JsonArray ?: throw SnoError("rule 8c: facecolors is not an array")
            val out = ArrayList<Int>(count)
            for (entry in arr) {
                val x = entry.int() ?: throw SnoError("rule 8c: a facecolors entry is not an integer")
                if (x < 0) {
                    if (out.isEmpty()) throw SnoError("rule 8c: the first entry must be an index, not a run")
                    val last = out.last()
                    repeat((-x).coerceAtMost(count.toLong() + 1).toInt()) { out.add(last) }
                } else {
                    if (x >= paletteSize) throw SnoError("rule 8c: face colour $x is outside the palette of $paletteSize")
                    out.add(x.toInt())
                }
                if (out.size > count) break
            }
            if (out.size != count) throw SnoError("rule 8c: facecolors expand to ${out.size} colours for $count faces")
            return out.toIntArray()
        }

        /**
         * §1.3a, §1.3b: absent, the built-in name, or a palette event reference
         * all read as the built-in (a reference is never load-bearing, and this
         * reader does not fetch one yet). An array carries 2 to 256 colours.
         */
        private fun resolvePalette(el: JsonElement?): IntArray {
            if (el == null) return SnoPalette.BUILT_IN
            if (el is JsonPrimitive && el.isString) {
                if (el.content == SnoPalette.NAME || PALETTE_REF.matches(el.content)) return SnoPalette.BUILT_IN
                throw SnoError("rule 8a: unknown palette ${el.content.take(40)}")
            }
            val arr = el as? JsonArray ?: throw SnoError("rule 8a: palette is neither a name, a reference, nor an array")
            if (arr.size !in 2..256) throw SnoError("rule 8a: a palette carries 2 to 256 colours, not ${arr.size}")
            return IntArray(arr.size) { i ->
                val c = (arr[i] as? JsonArray)?.takeIf { it.size == 3 }?.map { it.int() }
                if (c == null || c.any { it == null || it !in 0..255 }) {
                    throw SnoError("rule 8a: a palette entry is not three integers in 0..255")
                }
                rgbOf(c.map { it!!.toInt() })
            }
        }

        private fun rgbOf(c: List<Int>): Int = (c[0] shl 16) or (c[1] shl 8) or c[2]
    }
}
