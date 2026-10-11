package com.nostrvault.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import com.nostrvault.data.model.NIP10Thread
import com.nostrvault.ui.components.NostrMentions
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.flow.map

    /**
     * Build reply tags and the kind to sign them with. Answering a NIP-22
     * comment (kind 1111) sends a comment scoped to the same root
     * ([NIP10Thread.commentReplyTags]); everything else is a kind 1 reply
     * with NIP-10 e-tags (root/reply markers) + p-tag for the author.
     * Returns an empty list and kind 1 for new top-level notes.
     */
    internal fun ComposeNoteViewModel.buildReplyTags(): Pair<List<List<String>>, Int> {
        val parentId = replyToNoteId ?: return emptyList<List<String>>() to 1
        // A repost is answered as the note it carries: findNote on the
        // original's id can return the wrapper, whose kind (6) would make this
        // a NIP-22 comment and, for a bare repost, name the reposter.
        val parentNote = feedService.quoteTarget(parentId) ?: return emptyList<List<String>>() to 1

        val tags = mutableListOf<List<String>>()

        val effectiveParentKind = parentNote.effectiveKind
        // Automatic (Logen, 2026-10-03): a note gets a kind 1 reply, anything
        // else a NIP-22 comment. No switch to explain.
        val eventKind = NIP10Thread.replyKind(effectiveParentKind)
        if (eventKind == NIP10Thread.COMMENT_KIND) {
            // NIP-22: on a comment, copy its root and point at it; on anything
            // else the parent is the root (E, or A alone for addressables and
            // replaceables). The tags already name the parent author.
            tags.addAll(NIP10Thread.commentTags(
                parentId = parentNote.effectiveEventId,
                parentKind = effectiveParentKind,
                parentPubkey = parentNote.pubkey,
                parentTags = parentNote.tags,
                relayHint = configStore.config.value.nostrURL ?: "",
            ))
            // NIP-10 still holds for notification fan-out: carry the parent's
            // p tags (thread participants), deduplicated.
            val seen = mutableSetOf(parentNote.pubkey)
            for (tag in parentNote.tags) {
                if (tag.size >= 2 && tag[0] == "p" && seen.add(tag[1])) {
                    tags.add(listOf("p", tag[1]))
                }
            }
            return tags to eventKind
        }

        // Determine thread structure from parent's tags
        val parentETags = parentNote.tags.filter { it.size >= 2 && it[0] == "e" }
        val parentNonMentionETags = parentETags.filter { it.size < 4 || it[3] != "mention" }

        val parentNonMentionATags = parentNote.tags.filter { it.size >= 2 && it[0] == "a" }
            .filter { it.size < 4 || it[3] != "mention" }

        if (parentNonMentionETags.isEmpty()) {
            // Parent IS the root note — single e-tag with "root" marker. NIP-10: the
            // optional 5th element is the event author's pubkey, used by the outbox
            // model to know whose relays to fetch it from.
            tags.add(listOf("e", parentNote.id, "", "root", parentNote.pubkey))
        } else {
            // Parent is itself a reply — find the thread root
            val rootTag = parentNonMentionETags.firstOrNull { it.size >= 4 && it[3] == "root" }
            val threadRootId = rootTag?.get(1) ?: parentNonMentionETags[0][1]
            val threadRootSource = rootTag ?: parentNonMentionETags[0]
            val threadRootPubkey = if (threadRootSource.size >= 5) threadRootSource[4] else null
            tags.add(
                if (threadRootPubkey != null) listOf("e", threadRootId, "", "root", threadRootPubkey)
                else listOf("e", threadRootId, "", "root")
            )
            tags.add(listOf("e", parentNote.id, "", "reply", parentNote.pubkey))

            // A legacy thread under an addressable root carries its coordinate
            // forward. a/A tags have no marker field.
            val rootATag = parentNonMentionATags.firstOrNull { it.size >= 4 && it[3] == "root" }
                ?: parentNonMentionATags.firstOrNull()
            rootATag?.let { tags.add(listOf("a", it[1], "")) }
        }

        // Always tag the parent author
        tags.add(listOf("p", parentNote.pubkey))

        // NIP-10: "the reply event's p tags should contain all of E's p tags as well
        // as the pubkey of the event being replied to" — otherwise everyone else in
        // the thread except the immediate parent silently stops being notified.
        val seenPubkeys = mutableSetOf(parentNote.pubkey)
        for (tag in parentNote.tags) {
            if (tag.size >= 2 && tag[0] == "p" && seenPubkeys.add(tag[1])) {
                tags.add(listOf("p", tag[1]))
            }
        }

        return tags to eventKind
    }

    /**
     * Extracts hex pubkeys from `nostr:npub1.../nostr:nprofile1...` references in
     * [text] and returns new `["p", hex]` tags, skipping pubkeys already present in
     * [existing].
     */
    internal fun ComposeNoteViewModel.extractMentionPTags(text: String, existing: List<List<String>>): List<List<String>> {
        val seen = existing.filter { it.size >= 2 && it[0] == "p" }
            .map { it[1] }
            .toMutableSet()
        val result = mutableListOf<List<String>>()
        for (match in NostrMentions.MENTION_REGEX.findAll(text)) {
            val pubkey = NostrMentions.resolvePubkey(match.groupValues[1]) ?: continue
            if (seen.add(pubkey)) result.add(listOf("p", pubkey))
        }
        return result
    }
