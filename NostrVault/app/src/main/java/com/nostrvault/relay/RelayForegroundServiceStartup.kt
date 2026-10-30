package com.nostrvault.relay

import android.util.Log
import com.nostrvault.relay.RelayForegroundService.Companion.HEALTH_CHECK_INTERVAL_MS
import com.nostrvault.relay.RelayForegroundService.Companion.HEALTH_CHECK_TIMEOUT_MS
import com.nostrvault.relay.RelayForegroundService.Companion.MAX_RETRY_ATTEMPTS
import com.nostrvault.relay.RelayForegroundService.Companion.RESTART_BOOT_SETTLE_TIMEOUT_MS
import com.nostrvault.relay.RelayForegroundService.Companion.RETRY_DELAYS_MS
import com.nostrvault.relay.RelayForegroundService.Companion.SHUTDOWN_TIMEOUT_MS
import com.nostrvault.relay.RelayForegroundService.Companion.TAG
import com.nostrvault.relay.RelayForegroundService.Companion._readyForConnections
import com.nostrvault.relay.RelayForegroundService.Companion._relayStatus
import com.nostrvault.relay.RelayForegroundService.Companion.launchedInputs
import com.nostrvault.relay.RelayForegroundService.LifecycleState
import com.nostrvault.relay.RelayForegroundService.RelayStatus
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

    // ── Database lock clearing ─────────────────────────────────────

    /**
     * Delete stale BadgerDB LOCK files that persist after a Go crash.
     * Without this, the next start fails immediately with "Cannot acquire
     * directory lock" and the relay never comes up.
     *
     * Never while the last run is still shutting down ([RelayDrainState]):
     * those LOCK files belong to databases that are still open.
     */
    internal fun RelayForegroundService.clearDatabaseLocks(relayDataDir: File) {
        if (RelayDrainState.isDraining) {
            Log.w(TAG, "Not clearing database locks: the last relay run is still shutting down")
            return
        }
        var cleared = 0
        for (sub in RelayConfiguration.dbSubdirs) {
            for (prefix in listOf("db", "data")) {
                val lockFile = File(relayDataDir, "$prefix/$sub/LOCK")
                if (lockFile.exists()) {
                    lockFile.delete()
                    cleared++
                    Log.d(TAG, "Cleared stale lock: ${lockFile.absolutePath}")
                }
            }
        }
        if (cleared > 0) {
            Log.i(TAG, "Cleared $cleared stale database lock(s)")
        }
    }

    // ── TCP health check ───────────────────────────────────────────

    /**
     * Poll the relay's TCP port to confirm it's actually listening.
     * startRelay() returns as soon as the Go side spawns its HTTP server
     * goroutine, but that goroutine can crash moments later. This catches it.
     */
    private suspend fun RelayForegroundService.waitForRelayHealthy(port: Int): Boolean {
        val deadline = System.currentTimeMillis() + HEALTH_CHECK_TIMEOUT_MS
        var attempt = 0
        while (System.currentTimeMillis() < deadline) {
            if (isShuttingDown) return false
            attempt++
            try {
                val ours = withContext(Dispatchers.IO) { RelayIdentity.answersAsOurs(port, 1000) }
                // Something else holds the port: not ours, so not running.
                if (!ours) {
                    Log.e(TAG, "Port $port answers, but not as this app's relay (another relay app on the same port?)")
                    return false
                }
                Log.i(TAG, "Health check passed on attempt $attempt (port $port)")
                return true
            } catch (_: Exception) {
                delay(HEALTH_CHECK_INTERVAL_MS)
            }
        }
        Log.e(TAG, "Health check failed after ${HEALTH_CHECK_TIMEOUT_MS}ms ($attempt attempts)")
        return false
    }

    // ── Retry with backoff ─────────────────────────────────────────

    /**
     * Stop the Go side, wait with exponential backoff, clear locks, and retry.
     * Gives up after [MAX_RETRY_ATTEMPTS] and sets status to OFFLINE.
     */
    private suspend fun RelayForegroundService.attemptRetry(relayDataDir: File) {
        // A start refused because the last run still holds the databases is
        // not a failed start: wait for that run to let go, then start again
        // with a fresh count. Giving up here left the vault offline for good
        // seconds before the drain finished.
        if (RelayDrainState.awaitDrainedIfDraining { isShuttingDown }) {
            if (isShuttingDown) return
            Log.i(TAG, "Last relay run has shut down; starting again")
            lifecycleState = LifecycleState.IDLE
            retryCount = 0
            startGoRelay()
            return
        }
        if (retryCount >= MAX_RETRY_ATTEMPTS || isShuttingDown) {
            Log.e(TAG, "Giving up: retries=$retryCount/$MAX_RETRY_ATTEMPTS, shuttingDown=$isShuttingDown")
            lifecycleState = LifecycleState.IDLE
            _relayStatus.value = RelayStatus.OFFLINE
            updateNotification(RelayStatus.OFFLINE)
            return
        }

        val delayMs = RETRY_DELAYS_MS[retryCount.coerceAtMost(RETRY_DELAYS_MS.size - 1)]
        retryCount++
        Log.w(TAG, "Retry $retryCount/$MAX_RETRY_ATTEMPTS in ${delayMs}ms")

        // Stop Go side if still alive
        try {
            if (HavenBridge.isLoaded) {
                withContext(Dispatchers.IO) {
                    withTimeoutOrNull(SHUTDOWN_TIMEOUT_MS) {
                        HavenBridge.stopRelay()
                    }
                }
            }
        } catch (e: Throwable) {
            Log.w(TAG, "Error stopping relay before retry: ${e.message}")
        }

        lifecycleState = LifecycleState.IDLE
        delay(delayMs)

        clearDatabaseLocks(relayDataDir)
        startGoRelay()
    }

    // ── Stop before a restart ──────────────────────────────────────

    /**
     * Stops the Go relay and waits until its last run has really shut down
     * (its databases closed), so a restart neither gets "already running"
     * nor opens the databases beside the old run. Returns false if the
     * service is shutting down meanwhile.
     */
    internal suspend fun RelayForegroundService.stopGoRelayAndAwaitDrain(): Boolean {
        try {
            if (HavenBridge.isLoaded) {
                withContext(Dispatchers.IO) {
                    withTimeoutOrNull(SHUTDOWN_TIMEOUT_MS) { HavenBridge.stopRelay() }
                } ?: Log.w(TAG, "stopRelay() timed out before a restart")
            }
        } catch (e: Throwable) {
            Log.w(TAG, "Error stopping relay before a restart: ${e.message}")
        }
        if (!RelayDrainState.awaitDrained { isShuttingDown }) return false
        return !isShuttingDown
    }

    // ── Main relay start ───────────────────────────────────────────

    internal suspend fun RelayForegroundService.startGoRelay() {
        // Guard: only start from IDLE, and never while shutting down
        if (lifecycleState != LifecycleState.IDLE || isShuttingDown) {
            Log.i(TAG, "Skipping start: state=$lifecycleState, shuttingDown=$isShuttingDown")
            return
        }
        lifecycleState = LifecycleState.BOOTING

        if (!HavenBridge.isLoaded) {
            Log.e(TAG, "Cannot start relay: libhaven.so not loaded")
            lifecycleState = LifecycleState.IDLE
            _relayStatus.value = RelayStatus.OFFLINE
            stopSelf()
            return
        }

        _relayStatus.value = RelayStatus.BOOTING
        updateNotification(RelayStatus.BOOTING)

        try {
            // Set up relay data directory
            val relayDataDir = File(filesDir, "relay_data")
            RelayConfiguration.ensureDirectories(relayDataDir)

            // Clear stale database locks before every start
            clearDatabaseLocks(relayDataDir)

            val config = loadSavedConfig()

            currentRelayPort = config.relayPort

            // Everything below is written from these inputs, the same struct
            // RelayConfigApplier compares, so a setting the relay reads here
            // can never be missed by the settings auto-restart.
            val inputs = RelayConfiguration.launchInputs(config, relayDataDir)
            launchedInputs = inputs

            // Set environment variables
            for ((key, value) in inputs.env) {
                HavenBridge.setEnv(key, value)
            }

            // Fix file-based env vars: Go uses os.ReadFile with the
            // bare filename, but Android's CWD is NOT the relay data dir.
            // The lists are rewritten every boot: config is the source of truth
            // (there is no file-editing UI), and a list edited in Settings has
            // to reach the relay when the save restarts it. These used to be
            // written only when missing, so Blastr and import-seed edits never
            // reached the relay after the first boot.
            RelayConfiguration.writeRelayListFiles(config, inputs, relayDataDir)
            if (config.whitelistedNpubsFile.isNotEmpty()) {
                HavenBridge.setEnv("WHITELISTED_NPUBS_FILE", File(relayDataDir, config.whitelistedNpubsFile).absolutePath)
            }

            // Start the relay
            Log.i(TAG, "Starting Go relay on port ${config.relayPort} (attempt ${retryCount + 1})")
            withContext(Dispatchers.IO) {
                HavenBridge.startRelay(importMode = false)
            }

            // Verify the relay is actually listening before declaring success
            val healthy = waitForRelayHealthy(config.relayPort)
            if (!healthy) {
                Log.e(TAG, "Relay started but health check failed")
                attemptRetry(relayDataDir)
                return
            }

            // Success
            RelayDrainState.markRunning()
            lifecycleState = LifecycleState.RUNNING
            retryCount = 0
            _relayStatus.value = RelayStatus.RUNNING
            updateNotification(RelayStatus.RUNNING)
            Log.i(TAG, "Go relay started successfully and health check passed")
            restoreMesh()

            // Staggered startup: brief delay before client connections so the relay
            // settles first. The TCP health check above already proved it's listening,
            // so 500ms of margin is plenty for localhost.
            serviceScope.launch {
                delay(500)
                _readyForConnections.value = true
            }

            // Start the health watchdog so we detect if Go dies post-startup
            startHealthWatchdog()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start relay: ${e.message}")
            lifecycleState = LifecycleState.IDLE
            attemptRetry(File(filesDir, "relay_data"))
        }
    }

    // ── Settings restart ───────────────────────────────────────────

    /**
     * Restart the Go relay in place (the service, its foreground notification
     * and wake lock stay up) when the saved config would start it differently
     * from what it is running. Waits out a boot in progress first; a relay
     * that is stopped or retrying needs nothing, as its next start reads the
     * saved config from disk.
     */
    internal suspend fun RelayForegroundService.restartRelayInPlace() {
        withTimeoutOrNull(RESTART_BOOT_SETTLE_TIMEOUT_MS) {
            while (lifecycleState == LifecycleState.BOOTING && !isShuttingDown) delay(250)
        }
        if (lifecycleState != LifecycleState.RUNNING || isShuttingDown) {
            Log.i(TAG, "Settings restart skipped: state=$lifecycleState, shuttingDown=$isShuttingDown")
            return
        }
        val relayDataDir = File(filesDir, "relay_data")
        val saved = RelayConfiguration.launchInputs(loadSavedConfig(), relayDataDir)
        if (saved == launchedInputs) {
            Log.i(TAG, "Settings restart skipped: relay already runs the saved config")
            return
        }

        Log.i(TAG, "Relay settings changed; restarting relay to apply them")
        lifecycleState = LifecycleState.STOPPING
        healthWatchdogJob?.cancel()
        _readyForConnections.value = false
        _relayStatus.value = RelayStatus.BOOTING
        updateNotification(RelayStatus.BOOTING)
        try {
            withContext(Dispatchers.IO) {
                withTimeoutOrNull(SHUTDOWN_TIMEOUT_MS) {
                    if (HavenBridge.isLoaded) HavenBridge.stopRelay()
                }
            } ?: Log.w(TAG, "stopRelay() timed out during settings restart")
        } catch (e: Throwable) {
            Log.w(TAG, "Error stopping relay for settings restart: ${e.message}")
        }
        if (isShuttingDown) return

        lifecycleState = LifecycleState.IDLE
        retryCount = 0
        clearDatabaseLocks(relayDataDir)
        startGoRelay()
    }
