package com.nostrvault.ui.screens

import com.nostrvault.relay.RelayConfiguration
import com.nostrvault.relay.RelayDraft
import com.nostrvault.relay.RelayMatrix

// ── Starter relay list (Create an account) ──────────────────────
//
// A new account's first relay list (kind 10002) is shown before it is
// published: one line, the servers, Continue, and a Change link to the Relays
// screen (Logen 2026-10-31). The list is this device's Read relays, read when
// setup finishes, so a change saved there is what goes out.

    fun SetupWizardViewModel.continueFromStarterRelays() {
        _step.value = stepAfter(WizardStep.STARTER_RELAYS)
    }

/** The starter list's rules, pure for the tests. */
internal object StarterRelays {
    /**
     * A new account's list: this device's Read relays that can go on a public
     * list, once each. On a new install those are the five read servers
     * (primal, damus, snort, btcforplebs, wellorder; Logen 2026-10-31), and a
     * change saved in Relays shows up here.
     */
    fun from(read: List<String>): List<String> =
        RelayConfiguration.newAccountRelayListTags(read).map { it[1] }.filter(RelayDraft::listable)
            .distinctBy(RelayMatrix::key)

    /** The kind 10002 tags a new account publishes. */
    fun tags(read: List<String>): List<List<String>> = RelayConfiguration.newAccountRelayListTags(from(read))
}
