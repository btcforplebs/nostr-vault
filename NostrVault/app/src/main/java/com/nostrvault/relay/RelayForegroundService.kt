package com.nostrvault.relay

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import com.nostrvault.MainActivity
import com.nostrvault.R
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import java.io.File
import java.net.InetSocketAddress
import java.net.Socket

/**
 * Android Foreground Service that keeps the Go relay running 24/7.
 *
 * Lifecycle patterns ported from iOS RelayProcessManager.swift:
 *   - State machine (IDLE/BOOTING/RUNNING/STOPPING) prevents concurrent start/stop races
 *   - Database lock clearing before every start (BadgerDB LOCK files persist after crashes)
 *   - TCP health check after startRelay() to confirm HTTP server is actually listening
 *   - Automatic retry with exponential backoff (max 3 attempts)
 *   - Crash-restart detection via SharedPreferences (delays rapid restarts)
 *   - 5-second shutdown timeout (prevents zombie service state)
 */
class RelayForegroundService : Service() {

    companion object {
        const val NOTIFICATION_ID = 1001
        const val CHANNEL_ID = "nostrvault_relay"

        private const val TAG = "RelayService"
        private const val ACTION_STOP = "com.nostrvault.relay.STOP"
        private const val WAKELOCK_TAG = "NostrVault::RelayWakeLock"

        private const val MAX_RETRY_ATTEMPTS = 3
        private val RETRY_DELAYS_MS = longArrayOf(2_000, 5_000, 10_000)
        private const val HEALTH_CHECK_INTERVAL_MS = 500L
        private const val HEALTH_CHECK_TIMEOUT_MS = 15_000L
        private const val SHUTDOWN_TIMEOUT_MS = 5_000L
        private const val CRASH_RESTART_WINDOW_MS = 30_000L
        private const val CRASH_RESTART_DELAY_MS = 3_000L
        private const val PREFS_NAME = "relay_lifecycle"
        private const val PREF_LAST_START_TIME = "last_start_time"

        private const val WATCHDOG_INTERVAL_MS = 30_000L   // check every 30s
        private const val WATCHDOG_PROBE_TIMEOUT_MS = 2_000 // TCP probe timeout
        private const val WATCHDOG_MAX_FAILURES = 3         // consecutive failures before restart

        private val _relayStatus = MutableStateFlow(RelayStatus.OFFLINE)
        val relayStatus: StateFlow<RelayStatus> = _relayStatus.asStateFlow()

        private val _eventsStored = MutableStateFlow(0)
        val eventsStored: StateFlow<Int> = _eventsStored.asStateFlow()

        private val _connections = MutableStateFlow(0)
        val connections: StateFlow<Int> = _connections.asStateFlow()

        /** Feed connections should wait until this is true (3s after RUNNING). */
        private val _readyForConnections = MutableStateFlow(false)
        val readyForConnections: StateFlow<Boolean> = _readyForConnections.asStateFlow()

        // ── Error states (surfaced from RelayLogParser) ────────
        private val _isLocked = MutableStateFlow(false)
        val isLocked: StateFlow<Boolean> = _isLocked.asStateFlow()

        private val _isPortConflict = MutableStateFlow(false)
        val isPortConflict: StateFlow<Boolean> = _isPortConflict.asStateFlow()

        fun updateErrorStates(locked: Boolean, portConflict: Boolean) {
            _isLocked.value = locked
            _isPortConflict.value = portConflict
        }

        fun clearErrorStates() {
            _isLocked.value = false
            _isPortConflict.value = false
        }

        /**
         * Clear stale BadgerDB LOCK files from the relay data directory.
         * Can be called from UI without a service instance.
         */
        fun clearLocksPublic(context: Context) {
            val relayDataDir = File(context.filesDir, "relay_data")
            var cleared = 0
            for (sub in RelayConfiguration.dbSubdirs) {
                for (prefix in listOf("db", "data")) {
                    val lockFile = File(relayDataDir, "$prefix/$sub/LOCK")
                    if (lockFile.exists()) {
                        lockFile.delete()
                        cleared++
                    }
                }
            }
            if (cleared > 0) {
                Log.i(TAG, "Cleared $cleared stale database lock(s) via public method")
            }
            _isLocked.value = false
        }

        /**
         * Force stop, clear locks, and restart the relay.
         */
        fun forceRestart(context: Context) {
            stop(context)
            clearLocksPublic(context)
            clearErrorStates()
            // Small delay to let the service fully stop before restarting
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                start(context)
            }, 1500)
        }

        // ── Relay activity badge ────────────────────────────────
        // The red dot reflects ONLY inbound events from other people (replies,
        // reactions, zaps, reposts, DMs that tag you). It is driven by the live
        // log poller (see LogStore) detecting "in your inbox" / "in your chat
        // relay" lines -- NOT by the total stored-event count, which also grows
        // from your own posts, blasts, and private/outbox writes.
        private val _hasNewRelayActivity = MutableStateFlow(false)
        val hasNewRelayActivity: StateFlow<Boolean> = _hasNewRelayActivity.asStateFlow()

        fun markRelayViewed() {
            _hasNewRelayActivity.value = false
        }

        /** Light the red dot for an event that arrived from someone else. */
        fun markInboxActivity() {
            _hasNewRelayActivity.value = true
        }

        /** Update the displayed event-count stat. Does NOT affect the red dot. */
        fun updateEventsStored(count: Int) {
            _eventsStored.value = count
        }

        fun start(context: Context) {
            val intent = Intent(context, RelayForegroundService::class.java)
            context.startForegroundService(intent)
        }

        fun stop(context: Context) {
            val intent = Intent(context, RelayForegroundService::class.java)
            context.stopService(intent)
        }
    }

    enum class RelayStatus { BOOTING, IMPORTING, RUNNING, OFFLINE }

    /** Hilt accessor so this (non-injected) Service can reach singletons. */
    @EntryPoint
    @InstallIn(SingletonComponent::class)
    interface LogStoreEntryPoint {
        fun logStore(): LogStore
        fun localNotifier(): com.nostrvault.service.LocalNotificationService
    }

    // ── Lifecycle state machine (replaces bare `relayStarted` boolean) ──

    private enum class LifecycleState { IDLE, BOOTING, RUNNING, STOPPING }

    @Volatile private var lifecycleState = LifecycleState.IDLE
    @Volatile private var isShuttingDown = false
    private var retryCount = 0
    private var currentRelayPort = 3355

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val jsonCodec = Json { ignoreUnknownKeys = true; prettyPrint = true }
    private var wakeLock: PowerManager.WakeLock? = null
    private var healthWatchdogJob: Job? = null

    private val logStore: LogStore by lazy {
        EntryPointAccessors.fromApplication(applicationContext, LogStoreEntryPoint::class.java).logStore()
    }

    private val localNotifier: com.nostrvault.service.LocalNotificationService by lazy {
        EntryPointAccessors.fromApplication(applicationContext, LogStoreEntryPoint::class.java).localNotifier()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        // Own the live log poller for the whole service lifetime so the relay-activity
        // red dot is detected continuously (not only while the Dashboard is on-screen).
        // The poll loop idles harmlessly until the Go relay is loaded.
        // Route the relay's NOTIFY marker lines to the local notifier so inbound
        // mentions/DMs/zaps raise system notifications without a push server.
        localNotifier.ensureChannel()
        logStore.notifySink = { line -> localNotifier.onLogLine(line) }
        logStore.startPolling(serviceScope)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }

        try {
            startForeground(
                NOTIFICATION_ID,
                buildNotification(RelayStatus.BOOTING),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } catch (e: Exception) {
            Log.e(TAG, "startForeground failed: ${e.message}")
            _relayStatus.value = RelayStatus.OFFLINE
            stopSelf()
            return START_NOT_STICKY
        }
        acquireWakeLock()

        // If relay is already running (e.g. service restarted by the system or
        // user re-opened the app), skip the full boot cycle and just ensure
        // readyForConnections is true so the Dashboard can connect.
        if (lifecycleState == LifecycleState.RUNNING) {
            Log.i(TAG, "Relay already running, re-signalling readyForConnections")
            _relayStatus.value = RelayStatus.RUNNING
            _readyForConnections.value = true
            return START_STICKY
        }

        _readyForConnections.value = false

        serviceScope.launch {
            // Crash-restart detection: if we restarted very recently (e.g. START_STICKY
            // after a Go fatal error), delay to avoid re-triggering the same race.
            val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val lastStart = prefs.getLong(PREF_LAST_START_TIME, 0)
            val elapsed = System.currentTimeMillis() - lastStart
            if (elapsed in 1 until CRASH_RESTART_WINDOW_MS) {
                Log.w(TAG, "Rapid restart detected (last start ${elapsed}ms ago), delaying ${CRASH_RESTART_DELAY_MS}ms")
                delay(CRASH_RESTART_DELAY_MS)
            }
            prefs.edit().putLong(PREF_LAST_START_TIME, System.currentTimeMillis()).apply()

            startGoRelay()
        }

        // Restart if killed by the system
        return START_STICKY
    }

    override fun onDestroy() {
        Log.i(TAG, "Relay service stopping")
        isShuttingDown = true
        lifecycleState = LifecycleState.STOPPING
        _relayStatus.value = RelayStatus.OFFLINE
        _readyForConnections.value = false

        // Block until the Go relay shuts down (or we time out).
        // We must NOT cancel serviceScope before the shutdown coroutine finishes,
        // and the wake lock must stay held until databases are closed.
        try {
            runBlocking {
                withTimeoutOrNull(SHUTDOWN_TIMEOUT_MS) {
                    withContext(Dispatchers.IO) {
                        try {
                            if (HavenBridge.isLoaded) {
                                HavenBridge.stopRelay()
                            }
                        } catch (e: Throwable) {
                            Log.e(TAG, "Error stopping relay: ${e.message}")
                        }
                    }
                } ?: Log.w(TAG, "stopRelay() timed out after ${SHUTDOWN_TIMEOUT_MS}ms, force-resetting state")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Shutdown block failed: ${e.message}")
        }

        lifecycleState = LifecycleState.IDLE
        isShuttingDown = false

        // Release resources only after the Go side has stopped (or timed out)
        releaseWakeLock()
        serviceScope.cancel()
        super.onDestroy()
    }

    // ── Database lock clearing ─────────────────────────────────────

    /**
     * Delete stale BadgerDB LOCK files that persist after a Go crash.
     * Without this, the next start fails immediately with "Cannot acquire
     * directory lock" and the relay never comes up.
     */
    private fun clearDatabaseLocks(relayDataDir: File) {
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
    private suspend fun waitForRelayHealthy(port: Int): Boolean {
        val deadline = System.currentTimeMillis() + HEALTH_CHECK_TIMEOUT_MS
        var attempt = 0
        while (System.currentTimeMillis() < deadline) {
            if (isShuttingDown) return false
            attempt++
            try {
                withContext(Dispatchers.IO) {
                    Socket().use { socket ->
                        socket.connect(InetSocketAddress("127.0.0.1", port), 1000)
                    }
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
    private suspend fun attemptRetry(relayDataDir: File) {
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

    // ── Main relay start ───────────────────────────────────────────

    private suspend fun startGoRelay() {
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

            // Load saved config from disk (matches ConfigStore persistence path)
            val configFile = File(filesDir, "nostrvault_config.json")
            val config = if (configFile.exists()) {
                try {
                    jsonCodec.decodeFromString<HavenConfig>(configFile.readText())
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to parse config, using defaults: ${e.message}")
                    HavenConfig()
                }
            } else {
                Log.w(TAG, "No config file found, using defaults")
                HavenConfig()
            }

            currentRelayPort = config.relayPort

            // Set environment variables
            val envDict = RelayConfiguration.generateEnvDictionary(
                config = config,
                relayDataDir = relayDataDir,
            )
            for ((key, value) in envDict) {
                HavenBridge.setEnv(key, value)
            }

            // Fix file-based env vars: Go uses os.ReadFile with the
            // bare filename, but Android's CWD is NOT the relay data dir.
            // Override with absolute paths so the Go relay can find them.
            fun ensureRelayFile(
                envKey: String,
                fileName: String,
                defaultContent: List<String>,
                overwrite: Boolean = false,
            ) {
                if (fileName.isNotEmpty()) {
                    val file = File(relayDataDir, fileName)
                    if (overwrite || !file.exists()) {
                        val json = "[" + defaultContent.joinToString(",") { "\"$it\"" } + "]"
                        file.writeText(json)
                    }
                    HavenBridge.setEnv(envKey, file.absolutePath)
                }
            }
            ensureRelayFile("IMPORT_SEED_RELAYS_FILE", config.importSeedRelaysFile, config.importSeedRelays)
            ensureRelayFile("BLASTR_RELAYS_FILE", config.blastrRelaysFile, config.blastrRelays)
            // Overwrite: existing installs have a stale empty relays_dm.json from
            // when DM relays were hardcoded empty. Config is the source of truth
            // (no file-editing UI), so rewrite it each boot to surface tagged
            // notes from DM relays (e.g. nos.lol) in the inbox.
            ensureRelayFile("DM_RELAYS_FILE", "relays_dm.json", config.dmRelays, overwrite = true)
            if (config.whitelistedNpubsFile.isNotEmpty()) {
                HavenBridge.setEnv("WHITELISTED_NPUBS_FILE", File(relayDataDir, config.whitelistedNpubsFile).absolutePath)
            }
            if (config.blacklistedNpubsFile.isNotEmpty()) {
                HavenBridge.setEnv("BLACKLISTED_NPUBS_FILE", File(relayDataDir, config.blacklistedNpubsFile).absolutePath)
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
            lifecycleState = LifecycleState.RUNNING
            retryCount = 0
            _relayStatus.value = RelayStatus.RUNNING
            updateNotification(RelayStatus.RUNNING)
            Log.i(TAG, "Go relay started successfully and health check passed")

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

    // ── Health watchdog ────────────────────────────────────────────

    /**
     * Periodically probe the relay's TCP port while in RUNNING state.
     * If 3 consecutive probes fail, assume the Go side has died and
     * trigger a restart cycle.
     */
    private fun startHealthWatchdog() {
        healthWatchdogJob?.cancel()
        healthWatchdogJob = serviceScope.launch {
            var consecutiveFailures = 0
            while (lifecycleState == LifecycleState.RUNNING && !isShuttingDown) {
                delay(WATCHDOG_INTERVAL_MS)
                if (lifecycleState != LifecycleState.RUNNING || isShuttingDown) break

                val alive = try {
                    withContext(Dispatchers.IO) {
                        Socket().use { socket ->
                            socket.connect(
                                InetSocketAddress("127.0.0.1", currentRelayPort),
                                WATCHDOG_PROBE_TIMEOUT_MS,
                            )
                        }
                    }
                    true
                } catch (_: Exception) {
                    false
                }

                if (alive) {
                    consecutiveFailures = 0
                } else {
                    consecutiveFailures++
                    Log.w(TAG, "Health watchdog: probe failed ($consecutiveFailures/$WATCHDOG_MAX_FAILURES)")
                    if (consecutiveFailures >= WATCHDOG_MAX_FAILURES) {
                        Log.e(TAG, "Health watchdog: relay unresponsive, triggering restart")
                        _relayStatus.value = RelayStatus.OFFLINE
                        updateNotification(RelayStatus.OFFLINE)
                        lifecycleState = LifecycleState.IDLE
                        val relayDataDir = File(filesDir, "relay_data")
                        clearDatabaseLocks(relayDataDir)
                        retryCount = 0
                        // Enqueue restart through serviceScope to serialize with other lifecycle ops
                        serviceScope.launch {
                            startGoRelay()
                        }
                        break
                    }
                }
            }
        }
    }

    // ── Notifications ──────────────────────────────────────────────

    private fun buildNotification(status: RelayStatus): Notification {
        val statusText = when (status) {
            RelayStatus.BOOTING -> getString(R.string.relay_status_booting)
            RelayStatus.IMPORTING -> getString(R.string.relay_status_importing)
            RelayStatus.RUNNING -> getString(R.string.relay_status_running)
            RelayStatus.OFFLINE -> getString(R.string.relay_status_offline)
        }

        // Open app intent
        val openAppIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        // Stop relay intent
        val stopIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, RelayForegroundService::class.java).apply { action = ACTION_STOP },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(getString(R.string.relay_notification_title))
            .setContentText(statusText)
            .setSmallIcon(android.R.drawable.ic_dialog_info) // TODO: Custom icon
            .setOngoing(true)
            .setShowWhen(false)
            .setSilent(true)
            .setContentIntent(openAppIntent)
            .addAction(android.R.drawable.ic_media_pause, getString(R.string.relay_action_stop), stopIntent)
            .build()
    }

    private fun updateNotification(status: RelayStatus) {
        val notification = buildNotification(status)
        val manager = getSystemService(android.app.NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, notification)
    }

    // ── Wake lock ──────────────────────────────────────────────────

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return // already held, avoid double-acquire
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            WAKELOCK_TAG,
        ).apply {
            setReferenceCounted(false)
            // 4-hour ceiling: if the service crashes without calling releaseWakeLock(),
            // the lock auto-releases instead of draining the battery until reboot.
            acquire(4 * 60 * 60 * 1000L)
        }
        Log.d(TAG, "Wake lock acquired (4h timeout)")
    }

    private fun releaseWakeLock() {
        wakeLock?.let {
            if (it.isHeld) {
                it.release()
                Log.d(TAG, "Wake lock released")
            }
        }
        wakeLock = null
    }
}
