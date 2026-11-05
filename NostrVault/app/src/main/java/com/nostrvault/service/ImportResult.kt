package com.nostrvault.service

/**
 * The one line haven-go prints at the end of every import cycle (haven-go/import_result.go), and the only thing that
 * may call an import done. A failed, cut or cancelled import used to end as "Import completed" here too
 * (RESEARCH/NV_IMPORT_AUDIT_*_2026_11_05.md):
 *
 *     IMPORT_RESULT status=partial reason=walk_deadline,relay_dropped owner=812 tagged=40 relays=3/4 other_vault=none
 *
 * Twin of iOS `ImportResult.swift` (#1720): same parse, same words.
 */
data class ImportResult(
    val status: Status,
    val reasons: List<String>,
    val owner: Int,
    val tagged: Int,
    val relaysReached: Int,
    val relaysTotal: Int,
    /** "none", "reached" or "not_reached". */
    val otherVault: String,
) {
    enum class Status { COMPLETE, PARTIAL, FAILED, CANCELLED }

    val isComplete: Boolean get() = status == Status.COMPLETE
    val otherVaultNotReached: Boolean get() = otherVault == "not_reached"

    /** What the screens say once it ended. Only [Status.COMPLETE] says done. */
    val summary: String
        get() = when (status) {
            Status.COMPLETE -> COMPLETE_LINE
            Status.CANCELLED -> CANCELLED_LINE
            Status.PARTIAL ->
                if (reasons == listOf("other_vault_not_reached")) OTHER_VAULT_NOT_REACHED_LINE
                else "Imported ${"%,d".format(owner)} notes, but some may be missing. Run the import again to fill the gaps."
            Status.FAILED -> when (reasons.firstOrNull()) {
                "no_seed_relay" -> "Couldn't reach any relay. Check your connection, then try again."
                "already_running", "still_draining" -> "The vault was still busy. Try again in a moment."
                else -> COULD_NOT_START
            }
        }

    companion object {
        const val MARKER = "IMPORT_RESULT"
        /** haven-go reads the paired device's address for "Copy from my other vault" here ("" otherwise). */
        const val OTHER_VAULT_ENV = "IMPORT_OTHER_VAULT_RELAY"

        const val COMPLETE_LINE = "Import Complete!"
        const val CANCELLED_LINE = "Import cancelled"
        const val COULD_NOT_START = "Couldn't start, try again"
        const val OTHER_VAULT_NOT_REACHED_LINE = "Your other vault was not reached; your notes came from your relays"

        /** startRelay(importMode) returned but no result line came back. */
        val NO_RESULT = ImportResult(Status.FAILED, listOf("no_result"), 0, 0, 0, 0, "none")
        /** Cancelled before (or while) the Go side ran it, as the app saw it. */
        val CANCELLED = ImportResult(Status.CANCELLED, listOf("cancelled"), 0, 0, 0, 0, "none")
        /** The app couldn't run it (an exception before or around the Go call). */
        val APP_FAILED = ImportResult(Status.FAILED, listOf("app"), 0, 0, 0, 0, "none")

        /** The line anywhere in [text] (a log line keeps its timestamp in front). Unknown keys are ignored; no or an unknown status is null. */
        fun parse(text: String?): ImportResult? {
            if (text == null) return null
            val at = text.indexOf("$MARKER ")
            if (at < 0) return null
            val fields = text.substring(at + MARKER.length + 1).trim().split(' ')
                .mapNotNull { pair -> pair.split('=', limit = 2).takeIf { it.size == 2 }?.let { it[0] to it[1] } }
                .toMap()
            val status = when (fields["status"]) {
                "complete" -> Status.COMPLETE
                "partial" -> Status.PARTIAL
                "failed" -> Status.FAILED
                "cancelled" -> Status.CANCELLED
                else -> return null
            }
            val relays = fields["relays"].orEmpty().split('/').mapNotNull { it.toIntOrNull() }
            return ImportResult(
                status = status,
                reasons = fields["reason"].orEmpty().split(',').filter { it.isNotEmpty() },
                owner = fields["owner"]?.toIntOrNull() ?: 0,
                tagged = fields["tagged"]?.toIntOrNull() ?: 0,
                relaysReached = if (relays.size == 2) relays[0] else 0,
                relaysTotal = if (relays.size == 2) relays[1] else 0,
                otherVault = fields["other_vault"] ?: "none",
            )
        }
    }
}
