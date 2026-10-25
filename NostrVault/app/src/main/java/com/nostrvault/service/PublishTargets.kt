package com.nostrvault.service

import com.nostrvault.relay.DMInbox

/**
 * Where the owner's own event goes. NIP-65: an author's notes are read from
 * the write relays in their kind 10002, so those are the relays that must
 * take it. The app's Write relays (Settings) are sent to as well.
 *
 * Before this, Android sent only to the app's Write relays (the built-in
 * btcforplebs/damus/snort when never set) and counted "Posted" on any of
 * them, so an account made in another app never reached its own relays:
 * a reply sat on relay.damus.io, showed "Replied", and was missing from
 * nos.lol/primal/nostr.build where its followers look.
 */
object PublishTargets {

    /**
     * [confirmed] decide what the banner says: "Posted" once one of them
     * takes the event, a failure when none does. [alsoSend] get it too,
     * without being waited on.
     */
    data class Plan(val confirmed: List<String>, val alsoSend: List<String>) {
        val all: List<String> get() = confirmed + alsoSend
    }

    /**
     * [authorWriteRelays] is the author's kind 10002 write list, or null when
     * it isn't known (none published, or not found in time); then the app's
     * [appWriteRelays] decide instead. Loopback relays (this phone's own
     * relay) never count: they always accept, and nobody else can read them.
     */
    fun plan(authorWriteRelays: List<String>?, appWriteRelays: List<String>): Plan {
        val own = clean(authorWriteRelays.orEmpty())
        val app = clean(appWriteRelays)
        if (own.isEmpty()) return Plan(confirmed = app, alsoSend = emptyList())
        val ownKeys = own.map(::key).toSet()
        return Plan(confirmed = own, alsoSend = app.filter { key(it) !in ownKeys })
    }

    private fun clean(relays: List<String>): List<String> {
        val seen = HashSet<String>()
        return relays.map(DMInbox::normalizedRelayURL)
            .filter { it.isNotEmpty() && !NostrService.isLoopbackRelay(it) && seen.add(key(it)) }
    }

    private fun key(url: String) = DMInbox.normalizedRelayURL(url).lowercase()
}
