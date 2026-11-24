package com.nostrvault.ui.screens

import com.nostrvault.relay.RelayConfiguration
import com.nostrvault.relay.RelayDraft
import com.nostrvault.relay.RelayMatrix

// ── Starter relay list (Create an account) ──────────────────────
//
// A new account has no relay list (kind 10002). Setup publishes the
// recommended one when it finishes; it no longer asks (setup screens r3,
// Logen 2026-11-22, same as iOS #2410). Settings > Relays changes it later.

/** The starter list's rules, pure for the tests. */
internal object StarterRelays {
    /**
     * The recommended list: this device's Read relays that can go on a
     * public list, once each. On a new install those are the five read
     * servers (primal, damus, snort, btcforplebs; Logen 2026-10-31; wellorder
     * dropped 2026-11-12).
     */
    fun from(read: List<String>): List<String> =
        RelayConfiguration.newAccountRelayListTags(read).map { it[1] }.filter(RelayDraft::listable)
            .distinctBy(RelayMatrix::key)

    /** The kind 10002 tags for [urls]. */
    fun tags(urls: List<String>): List<List<String>> = RelayConfiguration.newAccountRelayListTags(from(urls))
}
