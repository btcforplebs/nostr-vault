package com.nostrvault.ui.components

/**
 * The web address a shared note points at.
 *
 * One definition, because there were about to be three: the broadcast sheet
 * built this string, the feed's Copy link built it again, and the next surface
 * that wants to share a note would have built a fourth. If the host ever
 * changes, it changes here.
 */
internal const val THREAD_LINK_HOST = "https://mynostrspace.com"

/** Shareable web link for a note, given its `nevent1…` (or `note1…`) reference. */
internal fun threadLink(reference: String): String = "$THREAD_LINK_HOST/thread/$reference"

/**
 * Hand a note to the system share sheet.
 *
 * One definition, because there were three — `FeedScreen`, `ProfileScreen` and
 * `NoteDetailScreen` each assembled the same `ACTION_SEND` chooser inline, and
 * they had already drifted: the profile copy fell back to `note.id`, which is
 * the repost wrapper's id on a kind-6, so sharing a repost with no text of its
 * own pointed at the repost rather than the note.
 */
internal fun shareNote(context: android.content.Context, note: com.nostrvault.data.model.FeedNote) {
    val text = note.content.ifBlank { "nostr:${note.effectiveEventId}" }
    val intent = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
        type = "text/plain"
        putExtra(android.content.Intent.EXTRA_TEXT, text)
    }
    context.startActivity(android.content.Intent.createChooser(intent, "Share Note"))
}
