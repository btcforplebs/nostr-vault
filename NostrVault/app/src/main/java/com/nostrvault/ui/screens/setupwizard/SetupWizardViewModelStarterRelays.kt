package com.nostrvault.ui.screens

import com.nostrvault.relay.RelayConfiguration
import com.nostrvault.relay.RelayDraft
import com.nostrvault.relay.RelayMatrix

// ── Starter relay list (Create an account) ──────────────────────
//
// A new account has no relay list (kind 10002). Setup shows the recommended
// servers as suggestions the owner can remove, add to, or take as they are
// with "Use recommended". Nothing is published until they confirm: Continue
// or Use recommended records the list, and setup publishes exactly that list
// when it finishes (Logen 2026-11-01, same as the iPhone).

    /** The list as edited on the step: the recommended servers until the owner changes it. */
    internal fun SetupWizardViewModel.starterRelayDraft(): List<String> =
        _starterRelayDraft.value ?: StarterRelays.from(configStore.config.value.activeFeedRelays)

    /** Adds [input] to the list; false (and no change) when it isn't a public wss:// server. */
    fun SetupWizardViewModel.addStarterRelay(input: String): Boolean {
        val next = StarterRelays.add(starterRelayDraft(), input) ?: return false
        _starterRelayDraft.value = next
        return true
    }

    fun SetupWizardViewModel.removeStarterRelay(url: String) {
        _starterRelayDraft.value = StarterRelays.remove(starterRelayDraft(), url)
    }

    /** Use recommended: back to the suggestions and confirm them. */
    fun SetupWizardViewModel.useRecommendedStarterRelays() {
        _starterRelayDraft.value = null
        confirmStarterRelays(StarterRelays.from(configStore.config.value.activeFeedRelays))
    }

    /** Continue: confirm the list as edited. */
    fun SetupWizardViewModel.continueFromStarterRelays() {
        confirmStarterRelays(starterRelayDraft())
    }

    private fun SetupWizardViewModel.confirmStarterRelays(urls: List<String>) {
        val key = generatedPkHex ?: return
        if (urls.isEmpty()) return
        starterRelaysConfirmed = StarterRelays.Confirmed(key, urls)
        _step.value = stepAfter(WizardStep.STARTER_RELAYS)
    }

/** The starter list's rules, pure for the tests. */
internal object StarterRelays {
    /**
     * The recommended list: this device's Read relays that can go on a
     * public list, once each. On a new install those are the five read
     * servers (primal, damus, snort, btcforplebs, wellorder; Logen 2026-10-31).
     */
    fun from(read: List<String>): List<String> =
        RelayConfiguration.newAccountRelayListTags(read).map { it[1] }.filter(RelayDraft::listable)
            .distinctBy(RelayMatrix::key)

    /** The kind 10002 tags for [urls]. */
    fun tags(urls: List<String>): List<List<String>> = RelayConfiguration.newAccountRelayListTags(from(urls))

    /** What the owner typed, as a wss:// address, or null when it can't go on a public list. */
    fun normalize(input: String): String? {
        val trimmed = input.trim().trimEnd('/')
        if (trimmed.isEmpty() || trimmed.any(Char::isWhitespace)) return null
        val url = if (trimmed.contains("://")) trimmed else "wss://$trimmed"
        return url.takeIf { from(listOf(it)).isNotEmpty() }
    }

    /** [list] with [input] added at the end, or null when it isn't valid. Already there: unchanged. */
    fun add(list: List<String>, input: String): List<String>? {
        val url = normalize(input) ?: return null
        return if (list.any { RelayMatrix.key(it) == RelayMatrix.key(url) }) list else list + url
    }

    fun remove(list: List<String>, url: String): List<String> =
        list.filterNot { RelayMatrix.key(it) == RelayMatrix.key(url) }

    /** The list the owner confirmed for [pubkey] with Continue or Use recommended. */
    data class Confirmed(val pubkey: String, val urls: List<String>)

    /**
     * What setup publishes as kind 10002 when it finishes: the confirmed
     * list, and only for the key it was confirmed for. Nothing confirmed,
     * nothing published.
     */
    fun finishTags(confirmed: Confirmed?, generatedHex: String): List<List<String>>? {
        val mine = confirmed?.takeIf { it.pubkey.equals(generatedHex, ignoreCase = true) } ?: return null
        return tags(mine.urls).ifEmpty { null }
    }
}
