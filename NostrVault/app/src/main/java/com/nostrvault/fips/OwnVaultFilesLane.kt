package com.nostrvault.fips

import android.util.Log
import java.io.File
import java.io.IOException

/**
 * Emoji notes for this phone's own vault, when it has no home vault because it is the vault. Save copies keeps the
 * blobs here, copy v2 takes them to the owner's other devices, and without an emoji note on this vault's `/files`
 * those devices showed them in Media (Tara's F1, 2026-11-13). The note goes to the vault's own `/files` on loopback
 * (haven-go files_relay.go: the relay port from this machine, written by this vault's own mesh key), signed with this
 * device's mesh key at send time ([HomeVaultSender.fileNoteSign]), never the account key or its signer.
 *
 * Its own queue file, so the home-vault queue and its caps stay as they were; the emoji notes' own cap applies.
 */
internal class OwnVaultFilesLane(dir: File, private val sender: HomeVaultSender) {
    private val queue = HomeVaultQueue(dir)

    val size: Int get() = queue.size

    /** Queue [drafts] (emoji notes); the hashes taken. Nothing without an own relay or with another account active. */
    fun add(drafts: List<HomeVaultQueue.FileNoteDraft>): Set<String> {
        if (!sender.ownerIsActive() || sender.ownFilesBase() == null) return emptySet()
        return queue.addFileNotes(drafts)
    }

    /** Send what is due to the own `/files`. Called inside the sender's drain lock. */
    suspend fun drain(userInitiated: Boolean) {
        if (queue.size == 0 || !sender.ownerIsActive()) return
        val base = sender.ownFilesBase() ?: return
        val now = System.currentTimeMillis()
        val gaveUp = queue.items().filter { HomeVaultRules.expired(it, now, false) }
        gaveUp.forEach { Log.w(TAG, "own vault: gave up on emoji note ${it.key.take(8)} after ${it.attempts} tries") }
        queue.applyOutcomes(gaveUp.map { it to null })
        val selection = HomeVaultRules.select(queue.items(), now, userInitiated, true, needsSignature = { false })
        // The engine reads this vault's own mesh key from the app, so ask with it (it is only the AUTH relay tag).
        val selfNpub = runCatching { MeshKeySigner.npub() }.getOrNull().orEmpty()
        val outcomes = mutableListOf<Pair<HomeVaultQueue.Item, HomeVaultQueue.Item?>>()
        try {
            for (item in selection.toTry) {
                val outcome = try {
                    sender.sendFileNote(base, item, selfNpub, restrictedWaits = true)
                } catch (e: IOException) {
                    // The relay, not the item (not up yet): try the lot later.
                    Log.w(TAG, "own vault: /files not reachable: ${e.message}")
                    break
                }
                outcomes += item to when (outcome) {
                    HomeVaultSend.SENT, HomeVaultSend.REJECTED -> null
                    HomeVaultSend.RETRY -> HomeVaultRules.afterRetry(item, now, false)
                }
            }
        } finally {
            queue.applyOutcomes(outcomes)
        }
    }

    private companion object {
        const val TAG = "OwnVaultFilesLane"
    }
}
