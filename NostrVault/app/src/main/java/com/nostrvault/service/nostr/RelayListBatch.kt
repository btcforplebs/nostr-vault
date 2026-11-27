package com.nostrvault.service

/**
 * Relay lists (kind 10002) waiting to be published to the lookup maps, in one
 * copy per batch. A cold start brings one list per follow; copying both whole
 * maps for each on Main was O(N²) and froze the app for tens of seconds
 * (Vault tab review 2026-11-27, finding 0). Thread-safe.
 *
 * Also keeps the newest created_at seen per pubkey, so a late older list
 * (from a lagging relay) never replaces a newer one.
 */
internal class RelayListBatch {
    private val lock = Any()
    private val createdAt = HashMap<String, Long>()
    private var read = HashMap<String, List<String>>()
    private var write = HashMap<String, List<String>>()
    private var scheduled = false

    /** Result of [offer]: whether the list is newest, and whether the caller must schedule a [drain]. */
    data class Offer(val accepted: Boolean, val schedule: Boolean)

    fun offer(pubkey: String, readRelays: List<String>, writeRelays: List<String>, at: Long): Offer = synchronized(lock) {
        val known = createdAt[pubkey]
        if (known != null && at < known) return Offer(accepted = false, schedule = false)
        createdAt[pubkey] = at
        if (readRelays.isNotEmpty()) read[pubkey] = readRelays
        if (writeRelays.isNotEmpty()) write[pubkey] = writeRelays
        val schedule = !scheduled
        scheduled = true
        Offer(accepted = true, schedule = schedule)
    }

    /** Takes every list offered since the last drain; the next [offer] schedules again. */
    fun drain(): Pair<Map<String, List<String>>, Map<String, List<String>>> = synchronized(lock) {
        val out = read to write
        read = HashMap()
        write = HashMap()
        scheduled = false
        out
    }

    /** created_at of the newest list seen for [pubkey], or null. */
    operator fun get(pubkey: String): Long? = synchronized(lock) { createdAt[pubkey] }
}
