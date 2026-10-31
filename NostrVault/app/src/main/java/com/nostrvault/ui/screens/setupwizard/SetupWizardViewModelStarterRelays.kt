package com.nostrvault.ui.screens

import com.nostrvault.relay.RelayConfiguration
import com.nostrvault.relay.RelayMatrix

// ── Starter relay list (Create an account) ──────────────────────
//
// A new account's first relay list (kind 10002) is shown before it is
// published: one line, the servers, Continue, and a Change link to the Relays
// screen (Logen 2026-10-31). The list is read from this device's settings
// when setup finishes, so a change saved there is what goes out.

    fun SetupWizardViewModel.continueFromStarterRelays() {
        _step.value = stepAfter(WizardStep.STARTER_RELAYS)
    }

/** The starter list's rules, pure for the tests. */
internal object StarterRelays {
    /** Left off a new account's list: damus rate-limits busy clients (#1373). */
    private val LEFT_OUT = setOf(RelayMatrix.key("wss://relay.damus.io"))

    /** The app's broadcast relays that can go on a public list, once each, without damus. */
    fun from(broadcast: List<String>): List<String> =
        RelayConfiguration.newAccountRelayListTags(broadcast).map { it[1] }.filter { RelayMatrix.key(it) !in LEFT_OUT }

    /** The kind 10002 tags a new account publishes. */
    fun tags(broadcast: List<String>): List<List<String>> = RelayConfiguration.newAccountRelayListTags(from(broadcast))
}
