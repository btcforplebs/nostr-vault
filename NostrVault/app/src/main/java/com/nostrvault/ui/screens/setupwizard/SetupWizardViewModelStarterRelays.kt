package com.nostrvault.ui.screens

import com.nostrvault.relay.RelayConfiguration
import com.nostrvault.relay.RelayMatrix

// ── Starter relay list (Create an account) ──────────────────────
//
// A new account's first relay list (kind 10002) is shown before anything is
// published: Use publishes it, Edit changes it first, Skip publishes nothing
// (Logen 2026-10-31). Nothing changes this device's own relay settings.

    /** Fills the list from the app's broadcast relays the first time the step opens. */
    fun SetupWizardViewModel.prepareStarterRelays() {
        if (_starterRelaysPrepared) return
        _starterRelaysPrepared = true
        _starterRelays.value = StarterRelays.from(configStore.config.value.activeBlastrRelays)
    }

    fun SetupWizardViewModel.removeStarterRelay(url: String) {
        _starterRelays.value = StarterRelays.removing(_starterRelays.value, url)
    }

    /** False when [typed] isn't a relay address anyone else could reach. */
    fun SetupWizardViewModel.addStarterRelay(typed: String): Boolean {
        val next = StarterRelays.adding(_starterRelays.value, typed) ?: return false
        _starterRelays.value = next
        return true
    }

    fun SetupWizardViewModel.useStarterRelays() {
        _publishStarterRelays.value = _starterRelays.value.isNotEmpty()
        _step.value = stepAfter(WizardStep.STARTER_RELAYS)
    }

    fun SetupWizardViewModel.skipStarterRelays() {
        _publishStarterRelays.value = false
        _step.value = stepAfter(WizardStep.STARTER_RELAYS)
    }

/** The starter list's rules, pure for the tests. */
internal object StarterRelays {
    /** The app's broadcast relays that can go on a public list, once each. */
    fun from(broadcast: List<String>): List<String> =
        RelayConfiguration.newAccountRelayListTags(broadcast).map { it[1] }

    fun removing(list: List<String>, url: String): List<String> =
        list.filter { RelayMatrix.key(it) != RelayMatrix.key(url) }

    /** [list] with [typed] at the end, unchanged if already there; null when it can't go on a public list. */
    fun adding(list: List<String>, typed: String): List<String>? {
        val url = RelayMatrix.relayURL(typed) ?: return null
        if (!RelayMatrix.isPublicRelay(url)) return null
        return if (list.any { RelayMatrix.key(it) == RelayMatrix.key(url) }) list else list + url
    }

    /** The kind 10002 tags to publish: none unless the person chose Use. */
    fun tags(list: List<String>, use: Boolean): List<List<String>> =
        if (use) RelayConfiguration.newAccountRelayListTags(list) else emptyList()
}
