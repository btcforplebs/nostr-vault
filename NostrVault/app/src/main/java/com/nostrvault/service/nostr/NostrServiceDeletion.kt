package com.nostrvault.service

/**
 * Deleting one of your own posts. Moved out of `NostrService.kt`, which is
 * over the file-size limit; see `deleteOwnEvents` there for the blob-driven
 * variant. iOS twin: `NostrService+Moderation.swift`.
 */

/** Publishes a NIP-09 deletion request (kind 5) for [noteId]. */
fun NostrService.deleteNote(noteId: String) {
    val tags = listOf(listOf("e", noteId))
    signAndPost(kind = 5, content = "", tags = tags)
}
