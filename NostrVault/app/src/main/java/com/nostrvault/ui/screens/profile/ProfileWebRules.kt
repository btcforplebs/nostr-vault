package com.nostrvault.ui.screens.profile

import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.TrustGate
import com.nostrvault.service.FeedFilterEngine

/**
 * What a profile page lets in from outside your web (audit
 * RESEARCH/NV_ANDROID_PROFILE_TABS/PROFILE_WOT_LEAKS.md, Logen 2026-11-27).
 * The person's own notes are exempt (RESEARCH/NV_ONE_WOT_GATE.md §2);
 * everything other people bring in is judged against the account's web,
 * whatever the Global shield says.
 */
internal object ProfileWebRules {

    /**
     * A note that belongs on [owner]'s own tabs: one they wrote, or one they
     * reposted. Someone else's repost of their note (pubkey = owner,
     * repostedBy = that someone) is not theirs to show.
     */
    fun belongsTo(note: FeedNote, owner: String): Boolean =
        note.repostedBy?.let { it == owner } ?: (note.pubkey == owner)

    /**
     * A Tagged row passes when whoever brings it in is in [web]: the author,
     * or for a repost the reposter and the reposted note's author.
     * [web] empty (not loaded) fails closed: only [always] passes.
     */
    fun allowsTagged(note: FeedNote, web: Set<String>, always: Set<String>): Boolean {
        val reposter = note.repostedBy
        return if (reposter != null) TrustGate.allowsRepost(reposter, note.pubkey, web, always)
        else TrustGate.allows(note.pubkey, web, always)
    }

    /**
     * [notes] (the owner's own) with any repost of a blocked person left out.
     * The owner is exempt: it is their profile you opened.
     */
    fun withoutBlockedReposts(notes: List<FeedNote>, blocked: Set<String>, owner: String): List<FeedNote> {
        val others = blocked - owner
        if (others.isEmpty()) return notes
        return notes.filter { !it.isProfileRepost || !FeedFilterEngine.involvesBlocked(it, others) }
    }

    /**
     * The Followers number on someone's profile: the followers known to be
     * inside your web. [linked] are your follows who follow them (the
     * relay's links file, exact); [sampled] are followers seen on relays.
     * Null while the web hasn't loaded, so the header says "—", not 0.
     */
    fun followersInWeb(linked: Collection<String>, sampled: Collection<String>, isOutside: (String) -> Boolean, webLoaded: Boolean): Int? {
        if (!webLoaded) return null
        return (linked.asSequence() + sampled.asSequence()).distinct().count { !isOutside(it) }
    }
}
