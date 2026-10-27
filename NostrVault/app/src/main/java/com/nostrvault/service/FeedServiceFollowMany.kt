package com.nostrvault.service

import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import com.nostrvault.ui.notification.FollowKind

/**
 * Follows several people in one follow list, as setup's "Who told you about
 * Nostr Vault?" step does at the end. One publish, not one per person: each
 * list has to be signed a second after the last, so ten single follows took
 * ten seconds and ten events.
 *
 * Waits for the account's real list first ([FeedService.followListIsKnown]),
 * the same rule Follow keeps, so an existing account's follows are added to,
 * never replaced. If the list never loads, each follow is queued the way a
 * tap is, and applied when it does.
 */
internal suspend fun FeedService.followManyImpl(pubkeys: List<String>, account: String, label: String) {
    val hex = Regex("^[0-9a-f]{64}$")
    val wanted = pubkeys.map { it.lowercase() }.filter { hex.matches(it) }.distinct()
    if (wanted.isEmpty() || nostrService.isReadOnlyAccount()) return
    val known = withTimeoutOrNull(FOLLOW_MANY_WAIT_MS) {
        // A list still loading is waited for; none started yet is asked for.
        if (!_isLoadingContacts.value && !followListIsKnown.value) scope.launch { loadContactList() }
        followListIsKnown.first { it }
    } ?: false
    if (nostrService.activeHexPubkey != account) return
    if (!known) {
        wanted.forEach { queueFollowAction(it, follow = true) }
        return
    }
    val previous = _followedPubkeys.value
    val added = wanted.filter { it !in previous }
    if (added.isEmpty()) return
    val next = previous + added
    _followedPubkeys.value = next
    publishContactList(next, rollback = previous) {
        notificationManager.showFollow(label, FollowKind.FAILED(followFailedMessage(follow = true)))
    }
    recomputeFilteredNotes()
    resubscribePrimaryToConnected()
    notificationManager.showFollow(label, FollowKind.FOLLOWED, pubkey = added.first())
}

private const val FOLLOW_MANY_WAIT_MS = 60_000L
