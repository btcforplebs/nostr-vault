package com.nostrvault.fips

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import java.security.MessageDigest

/**
 * The B side's rules for the zip mesh copy (docs/MESH_COPY_V2_CONTRACT.md, fixtures in docs/fixtures/mesh-copy/,
 * which win over the prose). The engine makes the start call, checks the manifest and the free space, fetches the
 * chunks and restores; the app signs the one start, keeps the [Record] of what to resume and whom to catch up with,
 * and shows the `COPY` lines. Twin of the engine's `copyv2_rules.go` and the Apple lane's rules.
 */
object MeshCopyV2 {
    const val CHUNK = 4194304L
    const val START_PATH = "/copy/v2/start"
    const val NIP98_KIND = 27235

    /** B keeps this much free on top of the parts and the restored data (contract §3, `needs_space`). */
    const val HEADROOM_BYTES = 1L shl 30

    private const val MAX_FAILURES = 3

    // ---- Manifest (§3.1, manifest-v2-cases.json) ----

    data class Part(val name: String, val size: Long, val sha256: String, val chunk: Long, val chunks: List<String>)

    data class Manifest(
        val v: Int?,
        val id: String,
        val state: String,
        val error: String,
        val owner: String,
        val parts: List<Part>?,
        val zipKey: String,
        val settings: String,
    )

    fun parseManifest(raw: String): Manifest? = runCatching { manifest(Json.parseToJsonElement(raw)) }.getOrNull()

    fun manifest(el: JsonElement): Manifest? {
        val o = el as? JsonObject ?: return null
        val parts = (o["parts"] as? JsonArray)?.map { p ->
            val po = p as? JsonObject ?: return@map null
            Part(
                name = po.str("name"),
                size = (po["size"] as? JsonPrimitive)?.longOrNull ?: return@map null,
                sha256 = po.str("sha256"),
                chunk = (po["chunk"] as? JsonPrimitive)?.longOrNull ?: 0,
                chunks = (po["chunks"] as? JsonArray)?.map { (it as? JsonPrimitive)?.contentOrNull.orEmpty() } ?: return@map null,
            )
        }
        return Manifest(
            v = (o["v"] as? JsonPrimitive)?.intOrNull,
            id = o.str("id"),
            state = o.str("state"),
            error = o.str("error"),
            owner = o.str("owner"),
            parts = if (parts == null || parts.any { it == null }) null else parts.filterNotNull(),
            zipKey = o.str("zip_key"),
            settings = o.str("settings"),
        )
    }

    /** sha256 of the parts' sha256 values joined with "\n", in order. */
    fun zipKey(parts: List<Part>): String = sha256Hex(parts.joinToString("\n") { it.sha256 })

    /**
     * Null when B takes this manifest; else the contract's error code. A manifest still building or failed on A
     * answers with its state (`building`) or A's own error.
     */
    fun manifestError(m: Manifest, ownerHex: String): String? {
        when (m.state) {
            "building" -> return "building"
            "failed" -> return m.error.ifEmpty { "bad_manifest" }
            "ready" -> Unit
            else -> return "bad_manifest"
        }
        val v = m.v ?: return "bad_manifest"
        if (v > 2) return "unsupported_version"
        if (v != 2) return "bad_manifest"
        if (m.owner != ownerHex) return "wrong_owner"
        val parts = m.parts ?: return "bad_manifest"
        val names = parts.map { it.name }
        if (names != listOf("notes") && names != listOf("notes", "media")) return "bad_manifest"
        for (p in parts) {
            if (p.chunk != CHUNK || p.size < 0 || !isLowerHex64(p.sha256)) return "bad_manifest"
            if (p.chunks.size.toLong() != (p.size + CHUNK - 1) / CHUNK) return "bad_manifest"
            if (p.chunks.any { !isLowerHex64(it) }) return "bad_manifest"
        }
        if (m.zipKey != zipKey(parts)) return "bad_manifest"
        return null
    }

    // ---- Resume (§3.2, chunk-state-cases.json) ----

    data class Plan(val restart: Boolean, val need: Map<String, List<Int>>)

    /** What B still fetches: everything after a rebuilt zip (or with no state), else the chunks not yet done. */
    fun plan(m: Manifest, stateZipKey: String?, done: Map<String, List<Int>>): Plan {
        val parts = m.parts.orEmpty()
        val restart = stateZipKey != null && stateZipKey != m.zipKey
        val kept = if (stateZipKey == null || restart) emptyMap() else done
        return Plan(restart, parts.associate { p ->
            val have = kept[p.name].orEmpty().toSet()
            p.name to p.chunks.indices.filter { it !in have }
        })
    }

    /** A chunk failed its hash: the new count, and whether this one stops the copy (`hash_mismatch`). */
    fun chunkFailed(before: Int): Pair<Int, Boolean> = (before + 1).let { it to (it >= MAX_FAILURES) }

    // ---- Progress lines (§3.3, progress-v2-lines.json) ----

    val STAGES = setOf("building", "fetching", "restoring", "relays", "done", "failed")
    private val PARTS = setOf("notes", "media", "-")
    private val SOURCES = setOf("mesh", "relays")
    private val KEYS = listOf("stage", "part", "bytes", "items", "source")

    data class Line(
        val stage: String,
        val part: String,
        val bytes: Pair<Long, Long>,
        val items: Pair<Long, Long>,
        val source: String,
        val error: String,
    )

    /** `COPY stage=… part=… bytes=a/b items=a/b source=… [error=…]` anywhere in a log line, keys in that order. */
    fun parseLine(raw: String): Line? {
        val at = raw.indexOf("COPY ")
        if (at < 0 || (at > 0 && !raw[at - 1].isWhitespace())) return null
        val fields = raw.substring(at + 5).trim().split(Regex("\\s+")).map {
            val eq = it.indexOf('=')
            if (eq <= 0) return null
            it.substring(0, eq) to it.substring(eq + 1)
        }
        if (fields.size < KEYS.size || fields.take(KEYS.size).map { it.first } != KEYS) return null
        val v = fields.toMap()
        val stage = v.getValue("stage").takeIf { it in STAGES } ?: return null
        val part = v.getValue("part").takeIf { it in PARTS } ?: return null
        val source = v.getValue("source").takeIf { it in SOURCES } ?: return null
        val bytes = fraction(v.getValue("bytes")) ?: return null
        val items = fraction(v.getValue("items")) ?: return null
        return Line(stage, part, bytes, items, source, v["error"].orEmpty())
    }

    private fun fraction(s: String): Pair<Long, Long>? {
        val (a, b) = s.split('/').takeIf { it.size == 2 } ?: return null
        return (a.toLongOrNull() ?: return null) to (b.toLongOrNull() ?: return null)
    }

    /** The copy screen's own line for a progress [l] from [name]. */
    fun statusText(l: Line, name: String): String = when (l.stage) {
        "building" -> "$name is getting your vault ready…"
        "fetching" -> if (l.bytes.second > 0) "Copying ${l.part} from $name: ${percent(l.bytes)}%" else "Copying from $name…"
        "restoring" -> "Putting your ${if (l.part == "media") "photos and videos" else "notes"} in place…"
        "relays" -> "Bringing in anything else from your relays…"
        "done" -> if (l.error == "settings_refused") errorLine("settings_refused", name) else "Copied from $name"
        else -> failedLine(l, name).ifEmpty { "The copy from $name stopped" }
    }

    /** A failed line's own words; `needs_space` carries `bytes=<free>/<need>` (contract §3), so nothing is measured here. */
    fun failedLine(l: Line, name: String): String =
        if (l.error == "needs_space") errorLine("needs_space", name, gb(l.bytes.second, up = true), gb(l.bytes.first, up = false))
        else errorLine(l.error, name)

    private fun percent(f: Pair<Long, Long>): Long = (f.first * 100 / f.second).coerceIn(0, 100)

    // ---- Errors (§7, errors-v2.json) ----

    enum class Action { STOP, RESTART, WAIT, REFETCH, RELAYS, RESTART_NEXT_RECONNECT, RESUME_NEXT_RECONNECT, CONTINUE, KEEP_STATE }

    private data class Err(val http: Int?, val action: Action, val line: String)

    private val ERRORS = mapOf(
        "auth_refused" to Err(401, Action.STOP, "Couldn't sign in to {name}"),
        "not_owner" to Err(403, Action.STOP, "{name} belongs to another account"),
        "not_found" to Err(404, Action.RESTART, ""),
        "building" to Err(409, Action.WAIT, ""),
        "range" to Err(416, Action.REFETCH, ""),
        "no_space" to Err(507, Action.RELAYS, "{name} is short of space; copying from your relays instead"),
        "needs_space" to Err(null, Action.STOP, "Needs {need} free, this device has {free}"),
        "wrong_owner" to Err(null, Action.STOP, "{name} belongs to another account"),
        "unsupported_version" to Err(null, Action.STOP, "Update this app to copy from {name}"),
        "bad_manifest" to Err(null, Action.STOP, "{name} sent a copy this app can't read"),
        "hash_mismatch" to Err(null, Action.RESTART_NEXT_RECONNECT, "The copy from {name} arrived damaged; it starts over next time"),
        "unreachable" to Err(null, Action.RESUME_NEXT_RECONNECT, "Waiting for {name}"),
        "nothing_restored" to Err(null, Action.STOP, "Nothing in the copy could be restored"),
        "settings_refused" to Err(null, Action.CONTINUE, "Settings weren't copied: they held something that must stay on {name}"),
        "cancelled" to Err(null, Action.KEEP_STATE, "Copy stopped"),
    )

    val ERROR_CODES: Set<String> get() = ERRORS.keys

    fun action(code: String): Action? = ERRORS[code]?.action

    /** The error for an HTTP status from A, or null for one the contract doesn't name. */
    fun errorForHttp(status: Int): String? = ERRORS.entries.firstOrNull { it.value.http == status }?.key

    fun errorLine(code: String, name: String, need: String = "", free: String = ""): String =
        ERRORS[code]?.line.orEmpty().replace("{name}", name).replace("{need}", need).replace("{free}", free)

    // ---- Free space on B (§3, `needs_space`) ----

    /** Parts as received, the restored data (about the same again), and 1 GB. */
    fun needBytes(m: Manifest): Long = 2 * m.parts.orEmpty().sumOf { it.size } + HEADROOM_BYTES

    /** Null when [freeBytes] holds the copy; else the "Needs X GB free, this device has Y" line. */
    fun spaceLine(m: Manifest, freeBytes: Long, name: String): String? {
        val need = needBytes(m)
        if (freeBytes >= need) return null
        return errorLine("needs_space", name, gb(need, up = true), gb(freeBytes, up = false))
    }

    /** Bytes in GB with one decimal: a need rounded up, free space down, so the two never read the same. */
    fun gb(bytes: Long, up: Boolean): String {
        val g = 1L shl 30
        val tenths = if (up) (bytes * 10 + g - 1) / g else bytes.coerceAtLeast(0) * 10 / g
        return "${tenths / 10}.${tenths % 10} GB"
    }

    // ---- The start (§2) ----

    // The start's tags are [MeshKeyAuth.copyStartTags]: signed by this device's mesh key for A (`p`), never the owner's.

    data class Started(val id: String, val token: String)

    /** A's start answer: a 32-hex id and a 64-hex token, else null (never logged: the token is a bearer). */
    fun parseStart(raw: String): Started? = runCatching {
        val o = Json.parseToJsonElement(raw) as? JsonObject ?: return null
        val id = o.str("id")
        val token = o.str("token")
        if (!isLowerHex(id, 32) || !isLowerHex(token, 64)) return null
        Started(id, token)
    }.getOrNull()

    /**
     * `ws://127.0.0.1:<port>/<link token>` → (`http://127.0.0.1:<port>`, `/<link token>`): the base A's start is
     * signed for, and the prefix the request carries through the kept link.
     */
    fun splitLink(wsUrl: String): Pair<String, String>? {
        val u = runCatching { java.net.URI(wsUrl) }.getOrNull() ?: return null
        if (u.scheme != "ws" && u.scheme != "http") return null
        val host = u.host ?: return null
        val port = if (u.port > 0) ":${u.port}" else ""
        return "http://$host$port" to (u.rawPath ?: "").trimEnd('/')
    }

    // ---- B's own record: what to resume and whom to catch up with (twin of Apple's MeshCopyV2.Record) ----

    /** StartCopyFromC / CopySyncC answers. */
    const val RUN_STARTED = 0
    const val RUN_BUSY = 2
    const val RUN_RELAY_NOT_RUNNING = 3

    /** How long a start keeps trying while this device's relay comes up (code 3), and how often. */
    const val RELAY_WAIT_S = 90L
    const val RETRY_EVERY_S = 3L

    /** A catch-up with one linked device at most this often. */
    const val SYNC_EVERY_S = 15 * 60L

    /**
     * A copy the other device can't be reached for (`unreachable`, after the engine's own ~20 s) is tried again this
     * often, for [UNREACHABLE_RETRY_FOR_S] from the first miss; then it has failed and waits for Try again (Logen,
     * 2026-11-06). Before, it sat on "Waiting" until a reconnect. Twin of Apple's `unreachableRetryEvery`.
     */
    const val UNREACHABLE_RETRY_EVERY_S = 15L
    const val UNREACHABLE_RETRY_FOR_S = 5 * 60L

    /** What B does next about a copy it can't reach. */
    sealed interface Retry {
        /** Nothing to retry: no copy pending, or it isn't unreachable. */
        data object None : Retry
        /** Try again in [seconds]. */
        data class After(val seconds: Long) : Retry
        /** Tried for [UNREACHABLE_RETRY_FOR_S]: failed, Try again starts over. */
        data object GaveUp : Retry
    }

    /** The copy screen's line while B keeps trying, and once it has failed. */
    fun unreachableLine(r: Retry, name: String): String? = when (r) {
        Retry.None -> null
        is Retry.After -> "Can't reach $name yet. Trying again…"
        Retry.GaveUp -> "Couldn't reach $name. Make sure it's on and Nostr Vault is open, then try again."
    }

    /**
     * Kept in this app's prefs. No token and no address: the engine keeps the token (copy_peers.json and the copy
     * state), and the address is dialed fresh each time.
     */
    data class Record(
        val pending: Pending? = null,
        val copied: Map<String, Long> = emptyMap(),
        /** When the pending copy first couldn't reach its device (null while it can, or none is pending). */
        val unreachableSince: Long? = null,
    ) {
        /** The copy under way or cut short, and whether the next try needs a fresh signed start. */
        data class Pending(val peer: String, val name: String, val freshStart: Boolean)

        /** A finished `COPY` line from [peer], applied. */
        fun finished(l: Line, peer: String, now: Long): Record {
            if (l.stage != "done" && l.stage != "failed") return this
            if (l.stage == "done") return Record(null, copied + (peer to now))
            val since = if (l.error == "unreachable" && pending?.peer == peer) unreachableSince ?: now else null
            return when (action(l.error)) {
                Action.RESUME_NEXT_RECONNECT, Action.KEEP_STATE, Action.WAIT -> copy(pending = pending?.copy(freshStart = false))
                Action.RESTART_NEXT_RECONNECT, Action.RESTART -> copy(pending = pending?.copy(freshStart = true))
                // A stop (another owner, no space, an old app) or relays: no retry.
                else -> copy(pending = null)
            }.copy(unreachableSince = since)
        }

        /** A try that never reached the engine (no link to the device): a miss like the engine's `unreachable`. */
        fun missed(peer: String, now: Long): Record =
            if (pending?.peer != peer) this else copy(unreachableSince = unreachableSince ?: now)

        /** Try again, the device came back, or a new start: a fresh window. */
        fun retryNow(): Record = copy(unreachableSince = null)

        /** What to do about the pending copy now (see [Retry]). */
        fun retry(now: Long): Retry {
            val since = unreachableSince
            if (pending == null || since == null) return Retry.None
            return if (now - since >= UNREACHABLE_RETRY_FOR_S) Retry.GaveUp else Retry.After(UNREACHABLE_RETRY_EVERY_S)
        }

        /** The linked devices due a catch-up: copied before, not the one a copy is pending with, not in [SYNC_EVERY_S]. */
        fun syncDue(now: Long): List<String> =
            copied.filter { (peer, last) -> peer != pending?.peer && now - last >= SYNC_EVERY_S }.keys.sorted()

        fun toJson(): String = JsonObject(
            linkedMapOf(
                "pending" to (pending?.let {
                    JsonObject(
                        linkedMapOf("peer" to JsonPrimitive(it.peer), "name" to JsonPrimitive(it.name), "fresh" to JsonPrimitive(it.freshStart)),
                    )
                } ?: kotlinx.serialization.json.JsonNull),
                "copied" to JsonObject(copied.mapValues { JsonPrimitive(it.value) }),
                "unreachable_since" to (unreachableSince?.let(::JsonPrimitive) ?: kotlinx.serialization.json.JsonNull),
            ),
        ).toString()

        companion object {
            fun fromJson(raw: String?): Record = runCatching {
                val o = Json.parseToJsonElement(raw ?: return Record()) as JsonObject
                val p = o["pending"] as? JsonObject
                val pending = p?.let {
                    val peer = it.str("peer").takeIf(String::isNotEmpty) ?: return@let null
                    Pending(peer, it.str("name"), (it["fresh"] as? JsonPrimitive)?.contentOrNull == "true")
                }
                val copied = (o["copied"] as? JsonObject).orEmpty().mapNotNull { (k, v) -> (v as? JsonPrimitive)?.longOrNull?.let { k to it } }.toMap()
                val since = (o["unreachable_since"] as? JsonPrimitive)?.longOrNull
                Record(pending, copied, since)
            }.getOrDefault(Record())
        }
    }

    // ---- Helpers ----

    fun isLowerHex64(s: String) = isLowerHex(s, 64)

    private fun isLowerHex(s: String, len: Int) = s.length == len && s.all { it in '0'..'9' || it in 'a'..'f' }

    fun sha256Hex(s: String): String =
        MessageDigest.getInstance("SHA-256").digest(s.toByteArray()).joinToString("") { "%02x".format(it) }

    private fun JsonObject.str(k: String): String = (this[k] as? JsonPrimitive)?.takeIf { it.isString }?.content.orEmpty()
}
