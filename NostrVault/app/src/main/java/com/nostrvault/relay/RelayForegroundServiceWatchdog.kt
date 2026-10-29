package com.nostrvault.relay

import android.util.Log
import com.nostrvault.relay.RelayForegroundService.Companion.TAG
import com.nostrvault.relay.RelayForegroundService.Companion.WATCHDOG_INTERVAL_MS
import com.nostrvault.relay.RelayForegroundService.Companion.WATCHDOG_MAX_FAILURES
import com.nostrvault.relay.RelayForegroundService.Companion.WATCHDOG_PROBE_TIMEOUT_MS
import com.nostrvault.relay.RelayForegroundService.Companion._relayStatus
import com.nostrvault.relay.RelayForegroundService.LifecycleState
import com.nostrvault.relay.RelayForegroundService.RelayStatus
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

    // ── Health watchdog ────────────────────────────────────────────

    /**
     * Periodically probe the relay's TCP port while in RUNNING state.
     * If 3 consecutive probes fail, assume the Go side has died and
     * trigger a restart cycle.
     */
    internal fun RelayForegroundService.startHealthWatchdog() {
        healthWatchdogJob?.cancel()
        // The relay half of the widget snapshot: this service is the only
        // thing still running when the activity is gone, and it is the half
        // that changes on its own. The store skips the redraw when nothing
        // moved, so riding the watchdog's 30s tick costs a file read.
        serviceScope.launch {
            while (lifecycleState == LifecycleState.RUNNING || lifecycleState == LifecycleState.BOOTING) {
                com.nostrvault.widget.WidgetPublisher.publishRelayStats(applicationContext)
                delay(WATCHDOG_INTERVAL_MS)
            }
        }
        healthWatchdogJob = serviceScope.launch {
            var consecutiveFailures = 0
            while (lifecycleState == LifecycleState.RUNNING && !isShuttingDown) {
                delay(WATCHDOG_INTERVAL_MS)
                if (lifecycleState != LifecycleState.RUNNING || isShuttingDown) break

                // Our relay, not merely something on the port (RelayIdentity).
                val alive = try {
                    withContext(Dispatchers.IO) {
                        RelayIdentity.answersAsOurs(currentRelayPort, WATCHDOG_PROBE_TIMEOUT_MS)
                    }
                } catch (_: Exception) {
                    false
                }

                if (alive) {
                    consecutiveFailures = 0
                } else {
                    consecutiveFailures++
                    Log.w(TAG, "Health watchdog: probe failed ($consecutiveFailures/$WATCHDOG_MAX_FAILURES)")
                    if (consecutiveFailures >= WATCHDOG_MAX_FAILURES) {
                        _relayStatus.value = RelayStatus.OFFLINE
                        updateNotification(RelayStatus.OFFLINE)
                        lifecycleState = LifecycleState.IDLE
                        val now = System.currentTimeMillis()
                        val wait = recordWatchdogRestart(now)
                        if (wait == null) {
                            Log.e(TAG, "Health watchdog: relay unresponsive after ${WatchdogRestartPolicy.MAX_RESTARTS} restarts in 6 h — leaving it offline until the app starts it")
                            break
                        }
                        Log.e(TAG, "Health watchdog: relay unresponsive, restarting in ${wait / 1000}s")
                        val relayDataDir = File(filesDir, "relay_data")
                        clearDatabaseLocks(relayDataDir)
                        retryCount = 0
                        // Enqueue restart through serviceScope to serialize with other lifecycle ops
                        serviceScope.launch {
                            delay(wait)
                            // Skips itself if someone started the relay while we waited.
                            startGoRelay()
                        }
                        break
                    }
                }
            }
        }
    }
