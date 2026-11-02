package com.nostrvault.data.model

/**
 * What a saved reply draft knows about the note it answers, from its own
 * saved tags, so the drafts list can name the parent before it loads.
 * iOS twin: DraftReplyParent.swift.
 */
object DraftReplyParent {
    /** The parent's author: the draft saves the parent's `p` tag before any other. */
    fun parentPubkey(draft: Draft): String? {
        if (draft.replyToId == null) return null
        return draft.tags.firstOrNull { it.size >= 2 && it[0] == "p" && it[1].isNotEmpty() }?.get(1)
    }

    /** "↩ name: first line of their note", or "↩ Reply to name" while it isn't loaded. */
    fun line(name: String, parentContent: String?): String {
        val first = parentContent?.lineSequence()?.map { it.trim() }?.firstOrNull { it.isNotEmpty() }
        return if (first == null) "↩ Reply to $name" else "↩ $name: $first"
    }
}
