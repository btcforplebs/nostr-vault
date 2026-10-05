package com.nostrvault.relay

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.text.DateFormat
import java.util.Date

/**
 * The relay's one-time full-history copy from the Mac relay and its
 * missing-events check, as written by haven-go (macsync.go) to
 * mac_sync_status.json in the relay data folder. Every field is optional so
 * a file from an older or newer relay still reads. Port of iOS
 * RelayConfiguration.MacSyncStatus and MacRelaySyncStatusView's wording.
 */
@Serializable
data class MacSyncStatus(
    @SerialName("mac_url") val macURL: String? = null,
    /** running | done | incomplete | failed */
    val state: String? = null,
    /** negentropy | paged */
    val method: String? = null,
    val posts: Int? = null,
    val mentions: Int? = null,
    /** -1: not measurable (paged fallback) */
    val missing: Int? = null,
    val error: String? = null,
    @SerialName("started_at") val startedAt: Long? = null,
    /** Heartbeat while running. */
    @SerialName("updated_at") val updatedAt: Long? = null,
    @SerialName("finished_at") val finishedAt: Long? = null,
)

object MacSync {
    const val STATUS_FILE = "mac_sync_status.json"

    private val json = Json { ignoreUnknownKeys = true }

    /**
     * The Mac address the relay is started with (MAC_RELAY_URL): the Mac's
     * outbox as wss://host, or ws:// when the address was typed plain. ""
     * without a Mac relay. Mirrors iOS RelayConfiguration.macRelayURL.
     */
    fun macRelayURL(config: HavenConfig): String {
        val base = config.macRelayNormalizedBase
        if (base.isEmpty()) return ""
        val typed = config.macRelayURL.trim().lowercase()
        val plain = typed.startsWith("ws://") || typed.startsWith("http://")
        return (if (plain) "ws://" else "wss://") + base
    }

    fun parse(text: String): MacSyncStatus? = runCatching { json.decodeFromString<MacSyncStatus>(text) }.getOrNull()

    fun read(relayDataDir: File): MacSyncStatus? =
        runCatching { File(relayDataDir, STATUS_FILE).readText() }.getOrNull()?.let(::parse)

    /** What the Sync section shows, given the status file and the Mac configured now. */
    data class View(
        val headline: String,
        val detail: String?,
        val running: Boolean,
        /** done | incomplete | failed | null (no result for this Mac yet) */
        val outcome: String?,
    )

    fun view(status: MacSyncStatus?, configuredMac: String, checkRequested: Boolean, nowSec: Long, formatDate: (Long) -> String = ::defaultDate): View {
        // Only a result for the Mac configured now counts.
        val current = status?.takeIf { it.macURL == configuredMac }
        // A copy refreshes its heartbeat every 20s; one silent for 90s died
        // with its relay and is retried on the next start.
        val beat = current?.updatedAt ?: current?.startedAt
        val stale = beat == null || nowSec - beat > 90
        val state = current?.state
        val running = state == "running" && !stale

        val headline = when {
            checkRequested -> "Checking with your Mac…"
            current == null || state == null -> "Full copy from your Mac hasn't run yet"
            state == "running" -> if (stale) "Copy was interrupted" else "Copying your full history from the Mac…"
            state == "done" -> if ((current.missing ?: 0) < 0) "Copied (this Mac can't be checked)" else "Everything copied · 0 missing"
            state == "incomplete" -> (current.missing ?: 0).let { if (it > 0) "$it still missing" else "Copy didn't finish" }
            state == "failed" -> "Couldn't copy from your Mac"
            else -> state
        }

        val detail: String? = when {
            current == null ->
                "It starts on its own shortly after the relay starts. After that, new posts and mentions keep syncing on their own."
            state == "running" ->
                if (stale) "The app closed during the copy. It picks up again next time the relay starts." else null
            else -> {
                val parts = mutableListOf("${current.posts ?: 0} posts and ${current.mentions ?: 0} mentions copied.")
                current.finishedAt?.let { parts.add("Checked ${formatDate(it)}.") }
                if (state == "incomplete" || state == "failed") {
                    current.error?.takeIf { it.isNotEmpty() }?.let { parts.add(it) }
                    parts.add("It tries again next time the app starts.")
                }
                if ((current.missing ?: 0) < 0) {
                    parts.add("Your Mac's relay is too old to compare lists, so it was copied page by page.")
                }
                parts.joinToString(" ")
            }
        }

        val outcome = state?.takeIf { it in setOf("done", "incomplete", "failed") }
        return View(headline, detail, running, outcome)
    }

    /**
     * Whether the relay took a "Check sync with Mac" request: the copy is
     * running, or started after the status seen when the button was tapped.
     */
    fun pickedUp(latest: MacSyncStatus?, before: MacSyncStatus?): Boolean =
        latest?.state == "running" || (latest?.startedAt ?: 0) > (before?.startedAt ?: 0)

    private fun defaultDate(sec: Long): String =
        DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(sec * 1000))
}
