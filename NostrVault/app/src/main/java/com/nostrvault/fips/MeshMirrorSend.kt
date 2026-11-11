package com.nostrvault.fips

import android.util.Log
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.io.IOException

/** How a feed Mirror's copy to one of the owner's mesh devices went. */
enum class MeshMirrorOutcome {
    /** The device has it now (or already had it). */
    SENT,

    /** Queued: not reachable now, or a passing refusal. It goes when the device is reachable. */
    WAITING,

    /** The device said no for good. */
    REFUSED,

    /** Not queued (the queue is full or the copy failed), so it will not go. */
    NOT_QUEUED,
}

/** One mesh device's part of a feed Mirror's result. */
data class MeshMirrorResult(val npub: String, val role: DeviceRole, val outcome: MeshMirrorOutcome)

/**
 * A feed Mirror's copy over FIPS (Logen 2026-11-11: "if in the 10063"). The blob goes only to the owner's send
 * targets ([MeshSendTargets]: the mobile vault and Macs) that are also a `fipsmesh://<npub>/` entry in [listed], the
 * owner's kind 10063. Queued mesh-key-only ([HomeVaultQueue.Item.meshKeyOnly]): neither this try nor a later
 * retry signs with the account key. Each device is tried once now, so the pill can say which ones have it; what
 * cannot go now stays queued for the retry timer.
 */
internal object MeshMirrorSend {
    /** The npubs a 10063's entries name as `fipsmesh://<npub>/`. */
    fun listedNpubs(serverList: List<String>): Set<String> =
        serverList.mapNotNull { FipsMediaRouter.meshNpubIn(it) }.toSet()

    /** How long the composer-style send waits for a background pass holding the lock. */
    const val LOCK_WAIT_MS = 10_000L

    fun outcomeOf(send: HomeVaultSend): MeshMirrorOutcome = when (send) {
        HomeVaultSend.SENT -> MeshMirrorOutcome.SENT
        HomeVaultSend.REJECTED -> MeshMirrorOutcome.REFUSED
        HomeVaultSend.RETRY -> MeshMirrorOutcome.WAITING
    }
}

/**
 * Queue [source] for each send target listed in [listed] and try each once now. Empty when the owner is not the
 * active account or no listed device is a send target: no 10063 entry, no mesh send.
 */
internal suspend fun HomeVaultSender.offerMirror(
    sha256: String,
    contentType: String,
    source: File,
    listed: Set<String>,
): List<MeshMirrorResult> {
    val lanes = lanes().filter { it.first.npub in listed }
    if (lanes.isEmpty()) return emptyList()
    val type = safeType(contentType)
    val queued = lanes.map { (target, q) ->
        val ok = try {
            q.addBlob(sha256, type, source.length(), meshKeyOnly = true) { source.copyTo(it, overwrite = true) }
        } catch (e: Exception) {
            Log.w(TAG, "mirror: could not queue ${sha256.take(8)} for ${target.npub.take(12)}: ${e.message}")
            false
        }
        Triple(target, q, ok)
    }
    // A background pass holding the lock (a long queue) sends it in its turn: report those as waiting.
    if (withTimeoutOrNull(MeshMirrorSend.LOCK_WAIT_MS) { drainLock.lock() } == null) {
        scheduleRetry()
        publish()
        return queued.map { (t, _, ok) -> MeshMirrorResult(t.npub, t.role, if (ok) MeshMirrorOutcome.WAITING else MeshMirrorOutcome.NOT_QUEUED) }
    }
    val results = try {
        queued.map { (target, q, ok) ->
            val outcome = if (ok) tryMirrorOnce(target, q, sha256) else MeshMirrorOutcome.NOT_QUEUED
            MeshMirrorResult(target.npub, target.role, outcome)
        }
    } finally {
        drainLock.unlock()
    }
    if (results.any { it.outcome == MeshMirrorOutcome.WAITING }) scheduleRetry()
    publish()
    return results
}

private suspend fun HomeVaultSender.tryMirrorOnce(target: MeshSendTarget, q: HomeVaultQueue, sha256: String): MeshMirrorOutcome {
    // Gone between the queueing and the lock: a pass already sent (or refused) it, and it said which in the card.
    val item = q.items().firstOrNull { it.key == sha256 && it.type == HomeVaultQueue.TYPE_BLOB }
        ?: return MeshMirrorOutcome.SENT
    val base = meshIngress(target.npub) ?: return MeshMirrorOutcome.WAITING
    val send = try {
        sendBlob(base, item, q, target.npub, ensureClient)
    } catch (e: IOException) {
        Log.w(TAG, "mirror: ${sha256.take(8)} to ${target.npub.take(12)}: ${e.message}")
        FipsMediaRouter.forget(target.npub)
        HomeVaultSend.RETRY
    } catch (e: kotlinx.coroutines.CancellationException) {
        throw e
    } catch (e: Throwable) {
        Log.e(TAG, "mirror: dropping ${sha256.take(8)} for ${target.npub.take(12)}", e)
        HomeVaultSend.REJECTED
    }
    record(item, send, target.npub, System.currentTimeMillis(), q, target.role)
    return MeshMirrorSend.outcomeOf(send)
}

private const val TAG = "HomeVault"
