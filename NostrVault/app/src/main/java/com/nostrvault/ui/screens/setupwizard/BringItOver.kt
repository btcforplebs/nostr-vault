package com.nostrvault.ui.screens

import com.nostrvault.fips.DeviceRole
import com.nostrvault.relay.MacSyncStatus

/**
 * Setup's "Copy from my other vault" (PLANS/NV_TWO_SCAN_PAIRING_PLAN.md §5a, lane E): the third answer in the import
 * choice, next to the backup and the relays (Logen 2026-11-05). The pure part: its words, and when the copy from the
 * other device counts as stalled. The small print is the only line with "mesh" in it; no other mesh, FIPS, address or
 * role words on these screens. Twin of iOS `BringItOver.swift`.
 */
object BringItOver {
    /** Logen-approved wording (2026-11-05). */
    const val COPY = "Copy from my other vault"
    const val COPY_DETAIL = "Your Mac or another device signed in as you. Scan two codes and it copies over the mesh."
    const val CANCEL = "Cancel"
    const val SCAN_TITLE = "Scan your other device"
    const val SCAN_BODY = "On your other device, open Vault › Your devices › Add, so it shows a code. Then scan it here."
    const val FALLBACK_LINE = "Couldn't reach your other device; getting your notes from your relays instead"

    /** No code scanned this long after Yes: carry on with the relays (§5a "no hello within 3 minutes"). */
    const val SCAN_WAIT_S = 180L
    /** The copy gains nothing for this long: it has stalled (§5a). */
    const val COPY_STALL_S = 120L

    fun showCodeTitle(name: String) = "Now let $name scan this"
    fun showCodeBody(name: String) = "Hold this phone up to $name's camera. It finishes by itself."
    fun linkedLine(name: String) = "Linked ✓ $name"

    /** What happens after the link: only a Mac keeps the full copy the relay can pull, today. */
    fun copiesFrom(role: DeviceRole): Boolean = role == DeviceRole.MAC

    fun copyingLine(name: String, posts: Int?): String =
        if (posts == null || posts <= 0) "Copying from $name…"
        else "Copying from $name… ${"%,d".format(posts)} notes so far"

    sealed interface Copy {
        data object Going : Copy
        data class Done(val posts: Int) : Copy
        /** Give up quietly and import from the relays. */
        data object Stalled : Copy
    }

    /**
     * The copy, judged from the relay's Mac sync status file. [linkedAt]: when the link was stored; a status from
     * before it is someone else's run. [lastProgressAt]: the last time [status] showed anything new.
     */
    fun judge(status: MacSyncStatus?, linkedAt: Long, lastProgressAt: Long, now: Long): Copy {
        val ours = status?.takeIf { (it.startedAt ?: 0) >= linkedAt - CLOCK_SLACK_S }
        when (ours?.state) {
            "done" -> return Copy.Done(ours.posts ?: 0)
            "failed" -> return Copy.Stalled
            // "incomplete": what came over came; the relays fill the rest.
            "incomplete" -> return if ((ours.posts ?: 0) > 0) Copy.Done(ours.posts ?: 0) else Copy.Stalled
        }
        return if (now - maxOf(linkedAt, lastProgressAt) > COPY_STALL_S) Copy.Stalled else Copy.Going
    }

    /** What counts as "something new" in the status file: more notes, or a fresher heartbeat. */
    fun progressKey(status: MacSyncStatus?): Pair<Int, Long>? =
        status?.let { (it.posts ?: 0) to (it.updatedAt ?: it.startedAt ?: 0) }

    private const val CLOCK_SLACK_S = 5L
}
