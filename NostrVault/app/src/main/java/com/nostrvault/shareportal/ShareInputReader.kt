package com.nostrvault.shareportal

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import com.nostrvault.service.readsForeignUri
import com.nostrvault.service.sharedStreamUris

/**
 * Turns what another app handed [com.nostrvault.ui.screens.shareportal.SharePortalActivity]
 * into a [ShareInput]. Mirrors the iOS extension's ShareInputReader.swift.
 *
 * The activity is exported: every extra is attacker-controlled. Nothing here is
 * trusted — extras are read inside runCatching (a bad Parcelable throws), text
 * is capped, file names are rebuilt, and a stream is only opened when
 * [readsForeignUri] says it is another app's provider.
 */
object ShareInputReader {

    /** What one share carried, with its files already copied out of the sender's grant. */
    data class Read(val input: ShareInput, val files: List<ShareFile>, val app: String?)

    /** Largest single file copied into the queue; a bigger one is left out. */
    const val MAX_FILE_BYTES = 200L * 1024 * 1024

    /** The text parts of a share. Pure, so the JVM tests drive it. */
    fun textInput(action: String?, text: CharSequence?, subject: CharSequence?, processText: CharSequence?): ShareInput {
        val t = text?.toString()?.let { ShareIntent.cap(it, ShareIntent.MAX_TEXT) }?.takeIf { it.isNotBlank() }
        val title = subject?.toString()?.let { ShareIntent.cap(it.trim(), ShareIntent.MAX_TITLE) }?.takeIf { it.isNotBlank() }
        return when (action) {
            // Text selected in any app's text menu: no URL comes with it.
            Intent.ACTION_PROCESS_TEXT -> ShareInput(
                selection = processText?.toString()?.let { ShareIntent.cap(it, ShareIntent.MAX_SELECTION) }?.takeIf { it.isNotBlank() },
            )
            Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE -> {
                // Chrome puts the page URL alone in EXTRA_TEXT and the title in
                // EXTRA_SUBJECT; the classifier finds a URL inside text itself.
                val url = t?.trim()?.takeIf { WHOLE_URL.matches(it) }?.let { ShareIntent.cap(it, ShareIntent.MAX_URL) }
                ShareInput(url = url, title = title, text = if (url != null) null else t)
            }
            else -> ShareInput()
        }
    }

    /** A file name safe to put on disk under `files/<id>/`, from whatever the sender called it. */
    fun safeFileName(raw: String?, mime: String?): String {
        var name = raw.orEmpty().substringAfterLast('/').substringAfterLast('\\')
            .replace(Regex("[\\u0000-\\u001f]"), "").trim().trimStart('.')
        if (name.length > 100) {
            val ext = name.substringAfterLast('.', "").take(10)
            name = name.take(100 - ext.length - 1) + if (ext.isNotEmpty()) ".$ext" else ""
        }
        if (name.isEmpty() || name == "..") {
            name = "shared" + when (mime?.lowercase()) {
                "application/pdf" -> ".pdf"
                "text/calendar" -> ".ics"
                else -> ""
            }
        }
        return name
    }

    /** Reads [intent], copying any streams for draft [draftId] into [queue] straight away. */
    fun read(context: Context, intent: Intent, draftId: String, queue: ShareQueue, app: String?): Read {
        val action = intent.action
        val input = textInput(
            action,
            runCatching { intent.getCharSequenceExtra(Intent.EXTRA_TEXT) }.getOrNull(),
            runCatching { intent.getCharSequenceExtra(Intent.EXTRA_SUBJECT) }.getOrNull(),
            runCatching { intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT) }.getOrNull(),
        )
        val files = if (action == Intent.ACTION_SEND || action == Intent.ACTION_SEND_MULTIPLE) {
            @Suppress("DEPRECATION")
            val stream = runCatching {
                if (action == Intent.ACTION_SEND) intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                else intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
            }.getOrNull()
            sharedStreamUris(stream).take(ShareIntent.MAX_FILES).mapNotNull { copy(context, it, draftId, queue) }
        } else emptyList()
        val withFiles = input.copy(files = files.map { ShareInputFile(it.mime, it.name) })
        return Read(withFiles, files, app?.let { ShareIntent.cap(it, ShareIntent.MAX_APP) })
    }

    /**
     * The read grant lasts only while the activity lives, so the bytes are
     * copied now. A file that is too big, refused, or unreadable is left out.
     */
    private fun copy(context: Context, uri: Uri, draftId: String, queue: ShareQueue): ShareFile? {
        if (!context.readsForeignUri(uri)) return null
        val resolver = context.contentResolver
        val mime = runCatching { resolver.getType(uri) }.getOrNull()?.let { ShareIntent.cap(it, 255) } ?: "application/octet-stream"
        val display = runCatching {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) c.getString(0) else null
            }
        }.getOrNull()
        var name = safeFileName(display ?: uri.lastPathSegment, mime)
        var target = queue.stageFile(draftId, name) ?: return null
        var n = 1
        while (target.exists() && n < 100) {
            name = "${n++}-$name"
            target = queue.stageFile(draftId, name) ?: return null
        }
        val bytes = runCatching {
            resolver.openInputStream(uri)?.use { input -> target.outputStream().use { out -> copyCapped(input, out) } }
        }.getOrNull()
        if (bytes == null || bytes < 0) { target.delete(); return null }
        return ShareFile(name, mime, ShareIntent.filePath(draftId, name), bytes)
    }

    /** Copies up to [MAX_FILE_BYTES]; returns -1 when the source is bigger. */
    private fun copyCapped(input: java.io.InputStream, out: java.io.OutputStream): Long {
        val buf = ByteArray(64 * 1024)
        var total = 0L
        while (true) {
            val r = input.read(buf)
            if (r < 0) return total
            total += r
            if (total > MAX_FILE_BYTES) return -1
            out.write(buf, 0, r)
        }
    }

    private val WHOLE_URL = Regex("^https?://\\S+$", RegexOption.IGNORE_CASE)
}
