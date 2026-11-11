package com.nostrvault.ui.components

import com.nostrvault.service.BlossomService.MirrorPushResult

/**
 * Where the feed Mirror pill's file ended up, once it is in the vault on this
 * phone. The pill's text and spoken label come from here, so they only claim
 * the servers that actually took the file.
 */
sealed interface MirrorOutcome {
    /** Vault on this phone, and every media server has it. */
    data object Everywhere : MirrorOutcome

    /** Vault on this phone, and [accepted] of [attempted] media servers. */
    data class SomeServers(val accepted: Int, val attempted: Int) : MirrorOutcome

    /** Vault on this phone; no media server took it. */
    data object ServersFailed : MirrorOutcome

    /** Vault on this phone; no media servers are added. */
    data object OnPhoneOnly : MirrorOutcome

    /** Already in the vault when opened; the servers were not checked. Tap to send it to them. */
    data object InVault : MirrorOutcome

    /** Short pill text. */
    val label: String
        get() = when (this) {
            Everywhere -> "Mirrored"
            is SomeServers -> "$accepted of $attempted servers"
            ServersFailed -> "On phone only"
            OnPhoneOnly, InVault -> "In vault"
        }

    /** TalkBack text: what happened, in full. */
    val spoken: String
        get() = when (this) {
            Everywhere -> "Saved to your vault and your media servers"
            is SomeServers -> "Saved to your vault and $accepted of $attempted media servers, tap to retry the rest"
            ServersFailed -> "Saved to your vault on this phone, media servers failed, tap to retry"
            OnPhoneOnly -> "Saved to your vault on this phone"
            InVault -> "In your vault on this phone, tap to copy to your media servers"
        }

    /** True when a tap could still get it onto more servers. */
    val canRetry: Boolean
        get() = this is SomeServers || this == ServersFailed || this == InVault

    /** True when every server holds it (green pill). */
    val complete: Boolean
        get() = this == Everywhere || this == OnPhoneOnly

    companion object {
        /**
         * From [com.nostrvault.service.pushToMissing]'s answer: null means every
         * server already had the file. A file the vault can't hand back
         * (NotOnDevice, e.g. over the 50 MB push cap) or an unsigned upload
         * counts as no server taking it.
         */
        fun of(push: MirrorPushResult?): MirrorOutcome = when (push) {
            null, is MirrorPushResult.AllAccepted -> Everywhere
            is MirrorPushResult.Partial -> SomeServers(push.accepted, push.attempted)
            MirrorPushResult.NoOutsideServer -> OnPhoneOnly
            is MirrorPushResult.AllFailed,
            MirrorPushResult.NotOnDevice,
            MirrorPushResult.SignerUnavailable -> ServersFailed
        }
    }
}

/** One of the owner's mesh devices in a Mirror's result, by the name My Devices shows. */
data class MeshDeviceLine(val name: String, val outcome: com.nostrvault.fips.MeshMirrorOutcome)

/**
 * A finished Mirror: the media servers' part ([servers]) and each mesh device the owner's 10063 lists ([mesh],
 * empty when it lists none). The pill reads its colour, text, spoken label and whether a tap retries from here.
 */
data class MirrorReport(val servers: MirrorOutcome, val mesh: List<MeshDeviceLine> = emptyList()) {
    private val meshSent get() = mesh.count { it.outcome == com.nostrvault.fips.MeshMirrorOutcome.SENT }

    /** Green: every server and every listed device has it. */
    val complete: Boolean get() = servers.complete && meshSent == mesh.size

    /** A tap can still reach more: a server lacks it, or a device is waiting or was never queued. */
    val canRetry: Boolean
        get() = servers.canRetry || mesh.any {
            it.outcome == com.nostrvault.fips.MeshMirrorOutcome.WAITING ||
                it.outcome == com.nostrvault.fips.MeshMirrorOutcome.NOT_QUEUED
        }

    val label: String
        get() = when {
            mesh.isEmpty() -> servers.label
            else -> "${servers.label} · $meshSent of ${mesh.size} ${if (mesh.size == 1) "device" else "devices"}"
        }

    /** The servers' sentence, then one per device: "Office Mac: sent". */
    val spoken: String
        get() = (listOf(servers.spoken) + mesh.map { "${it.name}: ${meshWords(it.outcome)}" }).joinToString(". ")

    private fun meshWords(o: com.nostrvault.fips.MeshMirrorOutcome) = when (o) {
        com.nostrvault.fips.MeshMirrorOutcome.SENT -> "sent over the mesh"
        com.nostrvault.fips.MeshMirrorOutcome.WAITING -> "waiting, goes when it is reachable"
        com.nostrvault.fips.MeshMirrorOutcome.REFUSED -> "refused it"
        com.nostrvault.fips.MeshMirrorOutcome.NOT_QUEUED -> "not sent, the queue is full"
    }
}
