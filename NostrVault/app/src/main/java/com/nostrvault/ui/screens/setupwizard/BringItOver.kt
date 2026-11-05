package com.nostrvault.ui.screens

import com.nostrvault.service.ImportResult

/**
 * Setup's "Copy from my other vault" (PLANS/NV_TWO_SCAN_PAIRING_PLAN.md §5a, lane E): the No to "New to Nostr
 * Vault?" (PLANS/NV_FIRST_RUN_ENTRY_PLAN_2026_11_05.md). After the two scans this phone imports from the other
 * device (one more seed relay, read over the link) since [START_DATE]; the normal relay import always runs after it,
 * since the copy reads only the other vault's public notes. A link or copy that fails falls back quietly to the relay
 * import. No mesh, FIPS, address or role words on these screens. Twin of iOS `OtherVaultCopy.swift` (#1720).
 */
object BringItOver {
    /** Logen-approved wording; the small print matches iOS (#1720). */
    const val COPY = "Copy from my other vault"
    const val COPY_DETAIL = "Links your devices, then brings your notes from your relays"
    const val CANCEL = "Cancel"
    /** The escape while linking: no other device to scan, so the notes come from relays (plan §1). */
    const val LOST_DEVICE = "Lost your other device? We'll bring your notes from relays"
    const val SCAN_TITLE = "Scan your other device"
    const val SCAN_BODY = "On your other device, open Vault › Your devices › Add, so it shows a code. Then scan it here."
    const val FALLBACK_LINE = "Your other vault was not reached; getting your notes from your relays instead"

    /** How far back the copy reads: the Mac backfill's epoch (macsync.go), not setup's 2023 relay-import start. */
    const val START_DATE = "2020-11-01"

    /** No code scanned this long after the choice: carry on with the relays (§5a). */
    const val SCAN_WAIT_S = 180L
    /** The copy shows no progress for this long: it has stalled (§5a). */
    const val COPY_STALL_S = 120L

    fun showCodeTitle(name: String) = "Now let $name scan this"
    fun showCodeBody(name: String) = "Hold this phone up to $name's camera. It finishes by itself."
    fun linkedLine(name: String) = "Linked ✓ $name"
    fun copyingLine(name: String): String = "Copying from ${name.trim().ifEmpty { "your other device" }}…"

    sealed interface Copy {
        data object Going : Copy
        /** Copied (all or part): the normal relay import runs next. */
        data object Done : Copy
        /** Not reached, failed, cancelled or stalled: the "not reached" line, then the relay import. */
        data object FallBack : Copy
    }

    /** How the copy's import ended, from haven-go's IMPORT_RESULT (iOS BringItOverStep.watch). */
    fun after(outcome: ImportResult): Copy = when {
        outcome.status == ImportResult.Status.FAILED || outcome.status == ImportResult.Status.CANCELLED -> Copy.FallBack
        outcome.status == ImportResult.Status.PARTIAL && outcome.otherVaultNotReached -> Copy.FallBack
        else -> Copy.Done
    }

    fun isStalled(lastProgressAt: Long, now: Long): Boolean = now - lastProgressAt >= COPY_STALL_S
}
