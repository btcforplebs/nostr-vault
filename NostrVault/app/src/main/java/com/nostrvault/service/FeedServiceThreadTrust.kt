package com.nostrvault.service

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map

/**
 * Who passes [com.nostrvault.data.model.TrustGate] in a note's thread
 * (Logen 2026-11-24): the feed's web ([myWeb]: the saved web plus your
 * follows, never a public key) without the people you blocked. Global's
 * Everyone shield is Global's alone, so a thread keeps to your web whatever
 * it says, as on iOS (`NoteDetailView.replyGate`). Empty while the web hasn't
 * loaded: only the thread's always-shown people pass.
 */
internal fun FeedService.threadTrustSet(): Set<String> = relayTabTrustedPubkeysImpl()

/** [threadTrustSet], re-read when the web, your follows, your blocks or the public keys change. */
internal val FeedService.threadTrustGateSet: Flow<Set<String>>
    get() = combine(
        _wotPubkeys,
        _followedPubkeys,
        configStore.config.map { it.blockedForActiveAccount() }.distinctUntilChanged(),
        com.nostrvault.util.PublicKeyRegistry.keys,
    ) { _, _, _, _ -> threadTrustSet() }.distinctUntilChanged()
