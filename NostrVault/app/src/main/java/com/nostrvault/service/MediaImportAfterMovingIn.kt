package com.nostrvault.service

import android.content.Context
import com.nostrvault.data.local.VaultHistory
import com.nostrvault.data.local.VaultHistoryStore
import com.nostrvault.di.ApplicationScope
import com.nostrvault.relay.RelayForegroundService
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.dropWhile
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.filterIsInstance
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Import media runs once by itself when the first Moving in finishes (setup's
 * way in, or the Vault's Moving in), so a
 * new vault holds the owner's media without anyone finding the button (it
 * used to hold only what was posted from the device). Once per device, never
 * on a plain start, and not at all if Import media already ran here.
 * iOS twin: `MediaImportAfterMovingIn.swift`.
 */
internal class MediaImportAfterMovingInRule(
    private val started: Flag,
    private val mediaImportedAt: () -> Long?,
    private val runImport: () -> Boolean,
) {
    interface Flag {
        fun get(): Boolean
        fun set()
    }

    /** A Moving in completed and the relay serves again. True when this started Import media. */
    fun movingInDone(): Boolean {
        if (started.get() || mediaImportedAt() != null) return false
        // A run already going (false) is that one run: it counts too.
        val ran = runImport()
        started.set()
        return ran
    }
}

@Singleton
class MediaImportAfterMovingIn @Inject constructor(
    @ApplicationContext context: Context,
    private val relayImport: RelayImportService,
    private val firstRun: FirstRunImport,
    private val blossom: BlossomService,
    private val vaultHistory: VaultHistoryStore,
    @ApplicationScope private val scope: CoroutineScope,
) {
    private val prefs = context.getSharedPreferences("media_import_after_moving_in", Context.MODE_PRIVATE)
    private val rule = MediaImportAfterMovingInRule(
        started = object : MediaImportAfterMovingInRule.Flag {
            override fun get() = prefs.getBoolean(KEY, false)
            override fun set() { prefs.edit().putBoolean(KEY, true).apply() }
        },
        mediaImportedAt = { vaultHistory.state.value[VaultHistory.Entry.MEDIA_IMPORT] },
        runImport = blossom::runMirror,
    )

    /** Watches for a completed Moving in: setup's (first run) or the Vault's (NostrVaultApp). */
    fun start() {
        // Setup's way in: the relay already serves when it lets the person in.
        scope.launch {
            firstRun.state.filterIsInstance<FirstRunImport.State.In>().collect { rule.movingInDone() }
        }
        // The Vault's Moving in (import mode), which restarts the relay at its end.
        scope.launch {
            // drop(1): the value at launch is not a Moving in that just finished.
            relayImport.importCompleted.drop(1).filter { it }.collect {
                // The relay restarts after an import; Import media needs it serving again
                // (a "ready" left over from before the import is skipped).
                withTimeoutOrNull(RELAY_WAIT_MS) {
                    RelayForegroundService.readyForConnections.dropWhile { it }.first { it }
                } ?: return@collect
                rule.movingInDone()
            }
        }
    }

    private companion object {
        const val KEY = "started"
        const val RELAY_WAIT_MS = 120_000L
    }
}
