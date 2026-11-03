package com.nostrvault.shareportal

import android.content.Context
import java.io.File

/**
 * Hand-off folder between the share sheet ([com.nostrvault.ui.screens.shareportal.SharePortalActivity])
 * and the app's review card. Mirrors NVShareQueue.swift; layout and rules are
 * docs/SHARE_PORTAL_CONTRACT.md §2:
 *
 * ```
 * queue/<id>.json            the intent, written last (the rename is the commit)
 * queue/files/<id>/<name>    its files, written first
 * queue/.partial-<id>.json   being written; never read
 * claimed/…                  the same layout, owned by the app until finished
 * ```
 *
 * Claiming moves the JSON first: only the caller whose move succeeded owns the
 * intent, so two claims (a rotation, Open now racing a resume) cannot act on it
 * twice. A claimed intent stays on disk until [finish], so the review survives
 * the process dying or Amber taking over the screen.
 */
class ShareQueue(private val queueDir: File, private val claimedDir: File) {

    /** Where a file for intent [id] goes before [commit]. Null for an unsafe id or name. */
    fun stageFile(id: String, name: String): File? {
        if (!ShareIntent.isValidId(id) || !ShareIntent.isValidFileName(name) || name == "..") return null
        val dir = File(queueDir, "files/$id").apply { mkdirs() }
        return File(dir, name)
    }

    /** Writes [intent] under a partial name and renames it into place. */
    fun commit(intent: ShareIntent): Boolean {
        if (!ShareIntent.isValidId(intent.id)) return false
        queueDir.mkdirs()
        val partial = File(queueDir, "$PARTIAL${intent.id}.json")
        val final = File(queueDir, "${intent.id}.json")
        val ok = runCatching {
            partial.writeText(intent.encode())
            partial.renameTo(final)
        }.getOrDefault(false)
        if (!ok) {
            partial.delete()
            File(queueDir, "files/${intent.id}").deleteRecursively()
        }
        return ok
    }

    /** Drops a draft's staged files (the person cancelled before sending). */
    fun discardStaged(id: String) {
        if (ShareIntent.isValidId(id)) File(queueDir, "files/$id").deleteRecursively()
    }

    /** Ids of committed intents still waiting in the queue. */
    fun pendingIds(): List<String> = idsIn(queueDir)

    val hasPending: Boolean get() = pendingIds().isNotEmpty()

    /**
     * Moves every waiting intent into the claimed folder and returns the ones
     * this call won. Anything that does not decode, or whose id does not match
     * its file name, is deleted with its files and never shown.
     */
    /** How old a staged files folder with no intent must be before [sweepOrphanFiles] deletes it. */
    var orphanAgeMs: Long = 60 * 60 * 1000L

    fun claimAll(): List<ShareIntent> {
        claimedDir.mkdirs()
        val won = mutableListOf<ShareIntent>()
        for (id in pendingIds()) {
            val src = File(queueDir, "$id.json")
            val dst = File(claimedDir, "$id.json")
            if (dst.exists()) continue
            if (!src.renameTo(dst)) continue
            val srcFiles = File(queueDir, "files/$id")
            if (srcFiles.exists()) {
                val dstFiles = File(claimedDir, "files/$id")
                dstFiles.parentFile?.mkdirs()
                dstFiles.deleteRecursively()
                if (!srcFiles.renameTo(dstFiles)) srcFiles.deleteRecursively()
            }
            val intent = readClaimed(id)
            if (intent == null) finish(id) else won += intent
        }
        sweepOrphanFiles()
        return won
    }

    /**
     * Files staged for a share whose JSON never got written (the share sheet
     * was killed before Send) would otherwise stay in `files/<id>` for good.
     * A folder with no `<id>.json` and older than [orphanAgeMs] is deleted;
     * the age keeps a share being written right now safe (Tron, PR 1610).
     */
    fun sweepOrphanFiles(now: Long = System.currentTimeMillis()) {
        val dirs = File(queueDir, "files").listFiles() ?: return
        for (dir in dirs) {
            if (File(queueDir, "${dir.name}.json").exists()) continue
            if (now - dir.lastModified() < orphanAgeMs) continue
            dir.deleteRecursively()
        }
    }

    /** Every claimed intent not yet finished, oldest first. Broken ones are removed. */
    fun claimed(): List<ShareIntent> = idsIn(claimedDir)
        .mapNotNull { id -> readClaimed(id) ?: run { finish(id); null } }
        .sortedWith(compareBy<ShareIntent> { it.createdAt }.thenBy { it.id })

    /** The claimed copy of one of [intent]'s files. */
    fun claimedFile(intent: ShareIntent, file: ShareFile): File? =
        if (file in intent.files) File(claimedDir, file.path) else null

    /** Done or dismissed: deletes the claimed intent and its files. */
    fun finish(id: String) {
        if (!ShareIntent.isValidId(id)) return
        File(claimedDir, "$id.json").delete()
        File(claimedDir, "files/$id").deleteRecursively()
    }

    private fun readClaimed(id: String): ShareIntent? {
        val raw = runCatching { File(claimedDir, "$id.json").readText() }.getOrNull() ?: return null
        return ShareIntent.decode(raw)?.takeIf { it.id == id }
    }

    private fun idsIn(dir: File): List<String> {
        val names = dir.listFiles()?.filter { it.isFile }?.map { it.name } ?: return emptyList()
        val ids = mutableListOf<String>()
        for (name in names) {
            if (name.startsWith(".") || !name.endsWith(".json")) continue
            val id = name.removeSuffix(".json")
            if (ShareIntent.isValidId(id)) ids += id else File(dir, name).delete()
        }
        return ids.sorted()
    }

    companion object {
        private const val PARTIAL = ".partial-"

        fun forApp(context: Context): ShareQueue = ShareQueue(
            File(context.filesDir, "share_queue"),
            File(context.filesDir, "share_claimed"),
        )
    }
}
