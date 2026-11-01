package com.nostrvault.ui.screens

import com.nostrvault.data.model.QueuedMediaPost

/**
 * Where one attachment's upload stands. Uploads start the moment a photo is
 * picked ([ComposeNoteUploads]); Post waits only on the ones not finished.
 */
sealed interface ComposeNoteUpload {
    /** Picked, waiting its turn (uploads go one at a time, in picked order). */
    data object Waiting : ComposeNoteUpload

    /** Sending; [progress] is 0..1. */
    data class Sending(val progress: Float) : ComposeNoteUpload

    /**
     * Finished. [media] has a null url when no outside server took it: it is
     * then on this device only and the post waits in the queue, as before.
     * [unreachable] is what was tried in that case.
     */
    data class Done(
        val media: QueuedMediaPost.Media,
        val unreachable: List<String> = emptyList(),
    ) : ComposeNoteUpload

    /** Could not even be saved here; Post tries it once more. */
    data class Failed(val message: String) : ComposeNoteUpload

    val finished: Boolean get() = this is Done || this is Failed
}

/**
 * The note being written: its text, its photos, each photo's upload, and
 * where in the text each photo was picked. One model, so the editor, the
 * preview and Post all read the same thing.
 *
 * A photo picked with the cursor inside the text is placed: its link goes in
 * at that spot once its upload lands, and edits before it move the spot
 * along. A photo picked with the cursor at the end (or no cursor) is not
 * placed, and its link goes at the end of the note, as it always has.
 */
data class ComposeNoteDraft(
    val text: String = "",
    val attachments: List<Attachment> = emptyList(),
    val uploads: Map<String, ComposeNoteUpload> = emptyMap(),
    /** Attachment id to the text offset its link goes in at, until it does. */
    val anchors: Map<String, Int> = emptyMap(),
) {
    fun upload(id: String): ComposeNoteUpload? = uploads[id]

    /** Photos still uploading (or waiting to): what Post waits on. */
    val unfinished: Int get() = attachments.count { it.hostedUrl == null && uploads[it.id]?.finished != true }

    /** The hosted link of [attachment], once there is one. */
    fun hostedUrl(attachment: Attachment): String? =
        attachment.hostedUrl ?: (uploads[attachment.id] as? ComposeNoteUpload.Done)?.media?.url

    /**
     * The link to take out of the text when [id] is removed: its uploaded
     * link, unless another photo still in the note has the same one (the same
     * picture picked twice shares a link). Media picked from the relay was
     * never placed, so nothing is taken out for it.
     */
    fun linkToRemove(id: String): String? {
        val removed = attachments.firstOrNull { it.id == id }?.takeIf { it.hostedUrl == null } ?: return null
        val url = hostedUrl(removed) ?: return null
        return url.takeIf { attachments.none { it.id != id && hostedUrl(it) == url } }
    }

    /**
     * The note's body as it would post now: the text, then the links of the
     * photos that are not already in it. Photos still uploading have no link
     * yet and are left out. Used by the preview; publish builds the same
     * thing from the finished uploads.
     */
    fun previewBody(): String = withLinksAtEnd(text.trim(), attachments.mapNotNull { hostedUrl(it) })

    companion object {
        /** A picked photo is placed when the cursor is inside the text, not at its end. */
        fun anchorFor(text: String, caret: Int?): Int? =
            caret?.takeIf { it in 0 until text.length }

        /**
         * Where [offset] in [old] ends up in [new], for one edit found by the
         * longest common prefix and suffix. Text typed exactly at the offset
         * goes after it, so a photo stays where the cursor was when it was
         * picked; an offset inside replaced text moves to the edit's start.
         */
        fun shift(old: String, new: String, offset: Int): Int {
            if (old == new) return offset.coerceIn(0, new.length)
            val max = minOf(old.length, new.length)
            var prefix = 0
            while (prefix < max && old[prefix] == new[prefix]) prefix++
            var suffix = 0
            while (suffix < max - prefix && old[old.length - 1 - suffix] == new[new.length - 1 - suffix]) suffix++
            val oldEnd = old.length - suffix
            return when {
                offset <= prefix -> offset
                offset >= oldEnd -> offset + (new.length - old.length)
                else -> prefix
            }.coerceIn(0, new.length)
        }

        /**
         * [text] with [url] on its own line at [at]. Returns the new text and
         * where the inserted run starts and how long it is, so a cursor after
         * it can move along.
         */
        fun insertLink(text: String, at: Int, url: String): Triple<String, Int, Int> {
            val i = at.coerceIn(0, text.length)
            val before = if (i == 0 || text[i - 1] == '\n') "" else "\n"
            val after = if (i == text.length || text[i] == '\n') "" else "\n"
            val run = before + url + after
            return Triple(text.substring(0, i) + run + text.substring(i), i, run.length)
        }

        /** [text] without the line [insertLink] put [url] on; unchanged when it isn't there. */
        fun removeLink(text: String, url: String): String {
            val i = text.indexOf(url)
            if (i < 0) return text
            var start = i
            var end = i + url.length
            // Take one of the line breaks around it, so no blank line is left.
            if (end < text.length && text[end] == '\n') end++
            else if (start > 0 && text[start - 1] == '\n') start--
            return text.substring(0, start) + text.substring(end)
        }

        /** [body] with each of [urls] not already in it on a new line at the end (the old behaviour). */
        fun withLinksAtEnd(body: String, urls: List<String>): String =
            urls.filterNot { body.contains(it) }.fold(body) { acc, url -> if (acc.isEmpty()) url else "$acc\n$url" }

        /** [body] with the links of [urls] taken out, for the queue, which puts every link at the end itself. */
        fun withoutLinks(body: String, urls: List<String>): String =
            urls.fold(body) { acc, url -> removeLink(acc, url) }.trim()
    }
}
