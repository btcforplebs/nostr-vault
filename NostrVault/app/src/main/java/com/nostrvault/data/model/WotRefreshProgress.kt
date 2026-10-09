package com.nostrvault.data.model

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import java.text.NumberFormat
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min

/**
 * How far the relay's web-of-trust rebuild has got, as the WOT tab's refresh
 * bar shows it. The relay reports it as JSON (Go wot.Progress); phases run
 * "follows", "lists" (in batches), "counting", then "saved", or "stopped"
 * when the relay stopped part way. Mirrors iOS.
 */
data class WotRefreshProgress(
    val running: Boolean,
    val phase: String,
    val batches: Int = 0,
    val batchesDone: Int = 0,
    /** Follow lists read so far, across every phase. */
    val lists: Long = 0,
    /** People in the web once saved. */
    val size: Int = 0,
    /** People this rebuild has found so far. Null from a relay older than the live fill. */
    val found: Int? = null,
    /** Of [found], how many weren't on the old map: the "↑ N new people" pill. */
    val new: Int? = null,
) {
    /**
     * How much of the rebuild step is done, 0 to 1, [phaseSeconds] since the
     * phase or the batches done last changed. A phase can run for most of a minute with nothing new to
     * report, so the bar creeps toward the next mark meanwhile (fast at first,
     * never reaching it) rather than sit still and look stuck. The batches of
     * follow lists are nearly all the work, so they get most of the bar.
     */
    fun fraction(phaseSeconds: Double): Double {
        val creep = 1 - exp(-max(0.0, phaseSeconds) / CREEP_SECONDS)
        return when (phase) {
            "follows" -> 0.02 + 0.2 * creep
            "lists" -> {
                val done = if (batches > 0) min(1.0, max(0, batchesDone).toDouble() / batches) else 0.0
                val next = if (batches > 0) min(1.0, (max(0, batchesDone) + 1).toDouble() / batches) else 1.0
                0.25 + 0.7 * (done + (next - done) * creep)
            }
            "counting" -> 0.97
            else -> 1.0
        }
    }

    /** What the phase says, or the stop notice. */
    val caption: String
        get() = when (phase) {
            "follows" -> "Reading your follow list…"
            // The relay counts lists per batch, so a running count sat still.
            "lists" -> if (batches > 1) "Reading your follows' lists… part ${min(batchesDone + 1, batches)} of $batches"
                else "Reading your follows' lists…"
            "counting" -> "Counting who your web trusts…"
            "saved" -> "Your web: ${count(size.toLong())} people"
            else -> "Rebuild stopped. Showing your last saved web."
        }

    /** [caption], plus the time so far while it runs, so a slow phase still reads as alive. */
    fun caption(elapsedSeconds: Long): String =
        if (running) "$caption · ${max(0L, elapsedSeconds)}s" else caption

    companion object {
        private val json = Json { ignoreUnknownKeys = true }

        /** The creep's time constant: about 63% of the way to the next mark after this long. */
        const val CREEP_SECONDS = 25.0

        private fun count(n: Long): String = NumberFormat.getIntegerInstance().format(n)

        /** Null for anything that isn't the relay's progress object. */
        fun parse(text: String?): WotRefreshProgress? {
            if (text.isNullOrBlank()) return null
            val obj = try { json.parseToJsonElement(text) as? JsonObject } catch (_: Exception) { null } ?: return null
            val running = (obj["running"] as? JsonPrimitive)?.booleanOrNull ?: return null
            val phase = (obj["phase"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return null
            return WotRefreshProgress(
                running = running,
                phase = phase,
                batches = (obj["batches"] as? JsonPrimitive)?.intOrNull ?: 0,
                batchesDone = (obj["batchesDone"] as? JsonPrimitive)?.intOrNull ?: 0,
                lists = (obj["lists"] as? JsonPrimitive)?.longOrNull ?: 0,
                size = (obj["size"] as? JsonPrimitive)?.intOrNull ?: 0,
                found = (obj["found"] as? JsonPrimitive)?.intOrNull,
                new = (obj["new"] as? JsonPrimitive)?.intOrNull,
            )
        }
    }
}

/**
 * A rebuild's newcomers from some index on, and how many there are in all
 * (Go `WotNewcomersC`). Mirrors iOS.
 */
data class WotNewcomers(val total: Int, val pubkeys: List<String>) {
    companion object {
        private val json = Json { ignoreUnknownKeys = true }

        /** Null for anything that isn't the relay's newcomers object. */
        fun parse(text: String?): WotNewcomers? {
            if (text.isNullOrBlank()) return null
            val obj = try { json.parseToJsonElement(text) as? JsonObject } catch (_: Exception) { null } ?: return null
            val total = (obj["total"] as? JsonPrimitive)?.intOrNull ?: return null
            val list = obj["pubkeys"] as? JsonArray ?: return null
            val pubkeys = list.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }
            return WotNewcomers(total, pubkeys)
        }
    }
}
