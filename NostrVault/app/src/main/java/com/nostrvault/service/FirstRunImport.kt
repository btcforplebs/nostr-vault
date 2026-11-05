package com.nostrvault.service

import android.content.Context
import com.nostrvault.di.ApplicationScope
import com.nostrvault.relay.RelayForegroundService
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import javax.inject.Inject
import javax.inject.Singleton

/**
 * First run on the relay's own import jobs (PLANS/NV_FIRST_RUN_ENTRY_PLAN_2026_11_05.md, "Calling order"):
 * HAVEN_FIRST_RUN=1, StartRelayC(0) (the relay serves at once and keeps its web to the follows), then
 * RunImportJobC("setup"); the person is in on `setup` done or partial. The old import mode (a stopped vault for
 * minutes) is no longer used here.
 */
@Singleton
class FirstRunImport @Inject constructor(
    @ApplicationContext private val context: Context,
    private val jobs: ImportJobService,
    private val configStore: com.nostrvault.data.local.ConfigStore,
    @ApplicationScope private val scope: CoroutineScope,
) {
    sealed interface State {
        data object Idle : State
        /** Starting the relay and the job. */
        data object Starting : State
        data class Bringing(val stored: Int) : State
        /** In: [partial] = some relay was slow or silent; its range is in older_relays for later. */
        data class In(val partial: Boolean, val stored: Int) : State
        data class Failed(val why: String) : State
    }

    private val _state = MutableStateFlow<State>(State.Idle)
    val state: StateFlow<State> = _state.asStateFlow()

    /** The other device's vault (local link address) for "Copy from my other vault": one more seed for `setup`. */
    @Volatile
    var otherVault: String? = null

    private var job: Job? = null

    /** Starts (or rejoins) the way in. Again after a failure. */
    fun start() {
        val s = _state.value
        if (s == State.Starting || s is State.Bringing || s is State.In) return
        _state.value = State.Starting
        job = scope.launch { run() }
    }

    private suspend fun run() {
        RelayForegroundService.firstRun = true
        RelayForegroundService.otherVaultRelay = otherVault
        // The other vault is one more seed for `setup` while it runs (through the config, so the relay's settings
        // check sees what it was started with); it comes off again when setup ends ([dropOtherVaultSeed]).
        otherVault?.let { url -> configStore.update { it.copy(importSeedRelays = (it.importSeedRelays + url).distinct()) } }
        RelayForegroundService.start(context, duringSetup = true)
        val up = withTimeoutOrNull(RELAY_WAIT_MS) { RelayForegroundService.readyForConnections.first { it } }
        if (up == null) return fail("relay_not_running")
        var started = false
        for (attempt in 1..START_TRIES) {
            when (jobs.run(ImportJobs.SETUP)) {
                ImportJobs.RUN_STARTED -> { started = true; break }
                // A setup cut earlier resumes by itself on the relay start: follow it.
                ImportJobs.RUN_BUSY -> if (jobs.read()?.job(ImportJobs.SETUP)?.isRunning == true) { started = true; break }
                ImportJobs.RUN_UNKNOWN -> return fail("unknown_job")
                else -> Unit
            }
            delay(RETRY_MS)
        }
        if (!started) return fail("not_started")
        while (true) {
            val setup = jobs.read()?.job(ImportJobs.SETUP)
            when {
                setup == null -> Unit
                setup.letsIn -> {
                    dropOtherVaultSeed()
                    _state.value = State.In(partial = setup.status == ImportJobs.PARTIAL, stored = setup.stored)
                    return
                }
                setup.status == ImportJobs.FAILED || setup.status == ImportJobs.CANCELLED -> return fail(setup.reason.ifEmpty { setup.status })
                else -> _state.value = State.Bringing(setup.stored)
            }
            delay(POLL_MS)
        }
    }

    private fun fail(why: String) {
        dropOtherVaultSeed()
        _state.value = State.Failed(why)
    }

    /** The link address dies with the link: it never stays among the seeds after setup. */
    private fun dropOtherVaultSeed() {
        val url = otherVault ?: return
        configStore.update { it.copy(importSeedRelays = it.importSeedRelays - url) }
        RelayForegroundService.otherVaultRelay = null
    }

    /** Back to the start (an account change in setup). */
    fun reset() {
        job?.cancel()
        _state.value = State.Idle
        otherVault = null
    }

    private companion object {
        const val RELAY_WAIT_MS = 90_000L
        const val START_TRIES = 30
        const val RETRY_MS = 1_000L
        const val POLL_MS = 1_000L
    }
}
