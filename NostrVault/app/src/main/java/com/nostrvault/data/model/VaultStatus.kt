package com.nostrvault.data.model

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlin.math.ceil
import kotlin.math.roundToInt

/**
 * What the desktop Vault's trust ranking, distant posts and rank hand-off are doing: the engine's status read
 * (haven-go/vault_status.go), over the mesh (`GET /copy/v2/sync/status`, docs/MESH_COPY_V2_CONTRACT.md §6.7).
 * Times are Unix seconds, 0 for never. Twin of iOS `VaultStatus.swift`.
 */
@Serializable
data class VaultStatus(
    val version: Int = 0,
    val at: Long = 0,
    /** "running", "paused", "idle" or "off". */
    val state: String = "",
    /** When paused: "app" (the Mac window is open, or Run in background is off) or "busy". */
    val pausedWhy: String? = null,
    val accounts: List<Account> = emptyList(),
) {
    @Serializable
    data class Account(
        val account: String,
        val running: Boolean = false,
        val ring: Int? = null,
        val ringDone: Int? = null,
        val ringTotal: Int? = null,
        val listsRead: Int? = null,
        val refresh: Boolean? = null,
        val cut: Boolean? = null,
        val finishedAt: Long = 0,
        val capped: Boolean? = null,
        val result: Result? = null,
        val distantAtBar: Int = 0,
        val distantFetchAt: Long? = null,
        val distantFetchPeople: Int? = null,
        val distantFetchNew: Int? = null,
        val handoffs: List<Handoff> = emptyList(),
    )

    @Serializable
    data class Result(
        val builtAt: Long,
        val people: Int,
        val maxHop: Int = 0,
        val rings: List<Int>? = null,
        /** distantByShown[s]: distant connections whose score rounds down to s. */
        val distantByShown: List<Int> = emptyList(),
        val viewBar: Double = 55.0,
    ) {
        /** Distant connections at or over [bar] (whole steps, as the slider). */
        fun distantAtBar(bar: Double): Int {
            val from = ceil(bar).toInt().coerceIn(0, 100)
            return distantByShown.drop(from).sum()
        }
    }

    @Serializable
    data class Handoff(
        /** The device's mesh key, hex. */
        val device: String,
        val role: String? = null,
        val tookAt: Long? = null,
        val builtAt: Long? = null,
        val checkedAt: Long = 0,
    )

    /** The status for [accountHex], or the first account when it is not ranked there. */
    fun account(accountHex: String): Account? =
        accounts.firstOrNull { it.account == accountHex.lowercase() } ?: accounts.firstOrNull()

    companion object {
        private val json = Json { ignoreUnknownKeys = true }

        fun decode(text: String): VaultStatus? =
            runCatching { json.decodeFromString(serializer(), text) }.getOrNull()?.takeIf { it.version >= 1 && it.state.isNotEmpty() }

        /** The engine's {"status": …} or {"error": "<code>"}: the status and its JSON, or the error. */
        fun answer(text: String): Pair<Pair<VaultStatus, String>?, String?> {
            val obj = runCatching { json.parseToJsonElement(text) as? JsonObject }.getOrNull() ?: return null to null
            obj["status"]?.toString()?.let { raw -> decode(raw)?.let { return (it to raw) to null } }
            return null to obj["error"]?.jsonPrimitive?.contentOrNull
        }
    }
}

/** The words the status cards show, the same as iOS `VaultStatusText`. */
object VaultStatusText {
    fun headline(s: VaultStatus): String = when (s.state) {
        "running" -> "Ranking your web"
        "paused" -> if (s.pausedWhy == "busy") "Paused while an import or copy runs" else "Paused while the window is open"
        "off" -> "Trust ranking is off here"
        else -> "Idle"
    }

    fun pausedHint(s: VaultStatus): String? =
        if (s.state == "paused" && s.pausedWhy != "busy") "It runs when the window is closed and Run in background is on." else null

    fun progress(a: VaultStatus.Account): String? {
        val ring = a.ring?.takeIf { it > 0 } ?: return null
        var line = "Ring $ring"
        val done = a.ringDone
        val total = a.ringTotal
        if (done != null && total != null && total > 0) line += " · ${n(done)} of ${n(total)} lists"
        else if (done != null && done > 0) line += " · ${n(done)} lists read"
        val read = a.listsRead
        if (a.running && read != null && read > 0) line += " · ${n(read)} read this run"
        else if (!a.running && a.cut == true) line += " · waiting to go on"
        return line
    }

    fun finished(a: VaultStatus.Account, nowS: Long): String {
        if (a.finishedAt <= 0) return if (a.result == null) "No ranking yet" else "Not finished since the last change"
        var line = "Finished ${ago(a.finishedAt, nowS)}"
        a.result?.let { line += " · ${n(it.people)} ${if (it.people == 1) "person" else "people"} ranked" }
        if (a.capped == true) line += " · stopped at the size cap"
        return line
    }

    fun distant(a: VaultStatus.Account, bar: Double?): String? {
        val r = a.result ?: return null
        val used = bar ?: r.viewBar
        val count = r.distantAtBar(used)
        return "${n(count)} distant ${if (count == 1) "connection" else "connections"} at your bar (${used.roundToInt()})"
    }

    fun distantFetch(a: VaultStatus.Account, nowS: Long): String {
        val at = a.distantFetchAt?.takeIf { it > 0 } ?: return "Distant posts not fetched yet"
        val fresh = a.distantFetchNew ?: 0
        val people = a.distantFetchPeople ?: 0
        return "Distant posts fetched ${ago(at, nowS)} · ${n(fresh)} new from ${n(people)} ${if (people == 1) "person" else "people"}"
    }

    fun handoff(h: VaultStatus.Handoff, nowS: Long): String {
        val took = h.tookAt?.takeIf { it > 0 } ?: return "Hasn't taken the ranking yet"
        return "Took it ${ago(took, nowS)}"
    }

    fun ago(unix: Long, nowS: Long): String {
        val secs = (nowS - unix).coerceAtLeast(0)
        return when {
            secs < 60 -> "just now"
            secs < 3600 -> "${secs / 60} min ago"
            secs < 86_400 -> "${secs / 3600} h ago"
            else -> (secs / 86_400).let { if (it == 1L) "1 day ago" else "$it days ago" }
        }
    }

    private fun n(v: Int): String = "%,d".format(v)
}

/**
 * Which of My Devices is this phone's desktop Vault: a desktop this device has caught up with, the latest first; else
 * the first desktop listed. Twin of iOS `DesktopVaultPick`.
 */
object DesktopVaultPick {
    fun <D> desktop(desktops: List<D>, npubOf: (D) -> String, lastSync: Map<String, Long>): D? =
        desktops.filter { (lastSync[npubOf(it)] ?: 0) > 0 }.maxByOrNull { lastSync[npubOf(it)] ?: 0 } ?: desktops.firstOrNull()

    /** A hand-off row's name: "This device", the My Devices name, or the role. */
    fun handoffName(h: VaultStatus.Handoff, named: Map<String, String>, selfHex: String?, roleLabel: (String) -> String?): String = when {
        selfHex != null && h.device == selfHex.lowercase() -> "This device"
        named[h.device] != null -> named.getValue(h.device)
        else -> h.role?.let(roleLabel) ?: "A paired device"
    }

    fun updated(fetchedAt: Long, nowS: Long): String = "Updated ${VaultStatusText.ago(fetchedAt, nowS)}"
}
