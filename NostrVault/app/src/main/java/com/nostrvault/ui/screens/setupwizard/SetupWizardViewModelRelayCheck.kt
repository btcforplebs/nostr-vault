package com.nostrvault.ui.screens

import androidx.compose.animation.*
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.lifecycle.viewModelScope
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.HavenConfig
import com.nostrvault.relay.RelayDraft
import com.nostrvault.service.RelayImportService
import com.nostrvault.setup.RelayCheck
import com.nostrvault.setup.RelayCheckProbe
import com.nostrvault.tutorials.TutorialCenter
import com.nostrvault.tutorials.TutorialID
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

    /**
     * Their relay list says where their notes are; the defaults are where
     * most people's notes also land. Each is asked for one note at once, and
     * the ones that don't answer are switched off. Runs once per visit.
     */
    fun SetupWizardViewModel.startRelayCheck(force: Boolean = false) {
        val pubkey = HavenBridge.decodeNpub(configStore.config.value.ownerNpub) ?: run {
            _relayRows.value = emptyList()
            _isCheckingRelays.value = false
            _error.value = "Couldn't read your key. Go back and paste it again."
            return
        }
        if (!force && pubkey == relayCheckPubkey) return
        relayCheckPubkey = pubkey
        _error.value = null
        viewModelScope.launch {
            _isCheckingRelays.value = true
            // The indexers too: a list made in another app may live only there (RelayDraft.INDEXERS).
            val list = runCatching {
                nostrService.fetchNewestReplaceable(10002, pubkey, alsoAsk = configStore.config.value.importSeedRelays + RelayDraft.INDEXERS)
            }.getOrNull()
            _relayRows.value = RelayCheck.rows(list?.tags ?: emptyList(), HavenConfig().importSeedRelays)
            _relayRows.value.map { row ->
                launch { probeRelayRow(row.url, pubkey) }
            }.joinAll()
            _isCheckingRelays.value = false
        }
    }

    private suspend fun SetupWizardViewModel.probeRelayRow(url: String, pubkey: String) {
        val result = RelayCheckProbe.check(url, pubkey)
        _relayRows.update { rows ->
            rows.map { if (it.url == url) it.copy(result = result, isOn = result.onByDefault) else it }
        }
    }

    fun SetupWizardViewModel.setRelayRowOn(url: String, on: Boolean) {
        _relayRows.update { rows -> rows.map { if (it.url == url && it.result.canImport) it.copy(isOn = on) else it } }
    }

    /** Adds a relay to the check and probes it. False when it isn't a relay address. */
    fun SetupWizardViewModel.addRelayCheckRow(raw: String): Boolean {
        val url = RelayCheck.normalize(raw) ?: return false
        if (_relayRows.value.any { it.url == url }) return true
        val pubkey = HavenBridge.decodeNpub(configStore.config.value.ownerNpub) ?: return false
        _relayRows.update { it + RelayCheck.Row(url, isYours = false) }
        viewModelScope.launch { probeRelayRow(url, pubkey) }
        return true
    }

    /** "Start import": the picks become what the import reads. */
    fun SetupWizardViewModel.startImportFromRelayCheck() {
        val picks = RelayCheck.importList(_relayRows.value)
        if (picks.isEmpty()) return
        configStore.update { it.copy(importSeedRelays = picks) }
        _step.value = stepAfter(WizardStep.RELAY_CHECK)
    }

    // ── Import tour ───────────────────────────────────────────────

    /**
     * Starts the import as soon as the tour shows. It runs in
     * [RelayImportService], not here, so "Keep it running in the background"
     * can leave setup with it still going.
     */
    fun SetupWizardViewModel.startImportTour() {
        val pubkey = HavenBridge.decodeNpub(configStore.config.value.ownerNpub).orEmpty()
        if (pubkey == importTourPubkey) return
        val sameAccountAgain = importTourPubkey == null
        importTourPubkey = pubkey
        _tourImportFailed.value = false
        _tourCounts.value = null
        if (sameAccountAgain && relayImportService.importCompleted.value && !relayImportService.isImporting.value) {
            loadTourCounts()
            return
        }
        if (relayImportService.isImporting.value) return
        // Same start as iOS. 2021 was tried there: the import walks history in
        // 10-day windows, each waiting on every relay, so two more years cost
        // minutes for everyone. Older notes can be pulled from Settings → Import.
        configStore.update { it.copy(importStartDate = IMPORT_TOUR_START_DATE) }
        relayImportService.importNotes()
        viewModelScope.launch {
            relayImportService.isImporting.first { it }
            relayImportService.isImporting.first { !it }
            if (!relayImportService.importCompleted.value) _tourImportFailed.value = true
        }
    }

    /** Real counts for the Ready card, once the relay is back up. */
    fun SetupWizardViewModel.loadTourCounts() {
        if (_tourCounts.value != null) return
        viewModelScope.launch {
            // The import restarts the relay when it finishes; give it a moment.
            for (attempt in 1..10) {
                statsService.fetchCountsByKind()
                if (statsService.loadedEventsCount.value > 0) break
                kotlinx.coroutines.delay(1_500)
            }
            val counts = statsService.kindCounts.value
            _tourCounts.value = Triple(counts[1] ?: 0, counts[7] ?: 0, statsService.loadedEventsCount.value)
        }
    }

    /**
     * Leaves the tour and finishes setup. Seeing every lesson card finishes
     * the tutorial (and covers Vault and Pocket relay); leaving before the
     * last one counts as skipped. The import carries on if it's still going.
     */
    fun SetupWizardViewModel.enterFromImportTour(sawEveryCard: Boolean, onComplete: () -> Unit) {
        val account = HavenBridge.decodeNpub(configStore.config.value.ownerNpub).orEmpty()
        if (sawEveryCard) {
            TutorialCenter.finish(TutorialID.IMPORT_TOUR, account)
        } else {
            TutorialCenter.skip(TutorialID.IMPORT_TOUR, account)
        }
        completeSetup(onComplete)
    }

    // ── Relays ───────────────────────────────────────────────────

    fun SetupWizardViewModel.addWizardRelay() {
        val url = _newRelayInput.value.trim()
        if (url.isBlank() || !url.startsWith("wss://")) return
        if (url in _wizardRelays.value) return
        _wizardRelays.value = _wizardRelays.value + url
        _newRelayInput.value = ""
    }

    fun SetupWizardViewModel.removeWizardRelay(url: String) {
        _wizardRelays.value = _wizardRelays.value - url
    }

    fun SetupWizardViewModel.advanceFromRelays() {
        configStore.update { it.copy(
            inboxRelays = _wizardRelays.value,
            feedRelays = _wizardRelays.value,
            macRelayURL = _macRelayInput.value.trim(),
        ) }
        _step.value = stepAfter(WizardStep.RELAYS)
    }

    // ── Import ───────────────────────────────────────────────────
