package com.nostrvault.service.shareportal.handlers

import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.ContactManager
import com.nostrvault.service.FeedService
import com.nostrvault.service.FollowActionError
import com.nostrvault.shareportal.ShareAction
import com.nostrvault.shareportal.ShareIntent

/**
 * A shared profile link (npub / nprofile, nostrvault.app/p/, njump): follow or block that person. Neither list is
 * written here: Follow is [FeedService.followUser] (the guarded kind 3 path in FeedServiceFollow: fetch the newest
 * list, apply only this change, ListShrinkRule, roll back on refusal) and Block is [FeedService.blockUser] (the kind
 * 10000 merged path every Block button uses). Tron review (list safety). Twin: ProfileShareHandler.swift.
 */
object ProfileShareHandler : ShareHandler {
    override val action = ShareAction.PROFILE
    override val isReady = true

    /** NIP-19 → hex with the checksum checked; null for anything that names nobody. */
    fun decode(id: String): String? = runCatching {
        if (id.startsWith("nprofile1")) HavenBridge.decodeNprofilePubkey(id) else HavenBridge.decodeNpub(id)
    }.getOrNull()

    /** The people the share names, hex, first one first. */
    fun people(intent: ShareIntent): List<String> =
        ProfileShareTarget.pubkeys(intent.source.url, intent.source.text, intent.source.selection, ::decode)

    sealed interface FollowOutcome {
        /** Followed, or already followed: FeedService said so on its own pill. */
        data object Done : FollowOutcome
        /** Queued by FeedService until the follow list has loaded: never published against a list it hasn't seen. */
        data object Queued : FollowOutcome
        data class Failed(val why: String) : FollowOutcome
    }

    fun follow(feedService: FeedService, hex: String): FollowOutcome {
        val result = feedService.followUser(hex)
        if (result.isSuccess) return FollowOutcome.Done
        return when (result.exceptionOrNull()) {
            is ContactManager.FollowActionError.AlreadyFollowing, is FollowActionError.AlreadyFollowing -> FollowOutcome.Done
            is ContactManager.FollowActionError.ContactsNotLoaded, is ContactManager.FollowActionError.ListUnavailable,
            is FollowActionError.ContactsNotLoaded -> FollowOutcome.Queued
            is FollowActionError.ReadOnly -> FollowOutcome.Failed("This account is read-only. Add its key to follow.")
            is ContactManager.FollowActionError.CannotUnfollowSelf -> FollowOutcome.Failed("That's you.")
            else -> FollowOutcome.Failed("Couldn't follow, try again")
        }
    }

    /** The active account's block (mute list), as every Block button does it. */
    fun block(feedService: FeedService, hex: String) = feedService.blockUser(hex)
}
