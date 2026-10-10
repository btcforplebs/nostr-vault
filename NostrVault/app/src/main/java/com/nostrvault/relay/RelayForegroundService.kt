package com.nostrvault.relay

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import com.nostrvault.MainActivity
import com.nostrvault.R
import com.nostrvault.data.model.VaultMode
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
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
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

        /** How long a settings restart waits for an in-progress boot to settle. */
        private const val RESTART_BOOT_SETTLE_TIMEOUT_MS = 60_000L
        /** How long [restartForSavedConfig] waits for the service to finish. */
        private const val RESTART_AWAIT_TIMEOUT_MS = 120_000L

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
        // reactions, zaps, reposts that tag you). It is driven by the live log
        // poller (see LogStore) reading the kind off "in your inbox" lines --
        // NOT by the total stored-event count, which also grows from your own
        // posts, blasts, and private/outbox writes.
        //
        // It keeps the SET of Vault lists that got something, so tapping in can
        // open the list the dot is for and the mode pill can mark each one (iOS
        // RelayProcessManager.newActivityModes, #476). DMs live under Profile,
        // whose own dot covers them.
        private val _newActivityModes = MutableStateFlow<Set<VaultMode>>(emptySet())
        val newActivityModes: StateFlow<Set<VaultMode>> = _newActivityModes.asStateFlow()

        private val _hasNewRelayActivity = MutableStateFlow(false)
        /** The Vault tab's red dot: some Vault list got something. */
        val hasNewRelayActivity: StateFlow<Boolean> = _hasNewRelayActivity.asStateFlow()

        /** Zaps Only hides the Likes list, so a like has no list to light. Set from the config. */
        @Volatile
        private var zapsOnlyMode = false

        // Monotonic counter alongside the red-dot latch: the relay's importer
        // writes inbound events straight to its DBs without notifying open REQ
        // subscriptions, so listeners (DashboardViewModel) use this tick to
        // re-send their subscriptions and pick the new events up live.
        private val _inboxActivityTick = MutableStateFlow(0L)
        val inboxActivityTick: StateFlow<Long> = _inboxActivityTick.asStateFlow()

        private fun setNewActivityModes(modes: Set<VaultMode>) {
            _newActivityModes.value = modes
            _hasNewRelayActivity.value = modes.isNotEmpty()
        }

        /** [mode] is on screen, so what came into it has been seen. */
        @Synchronized
        fun markRelayViewed(mode: VaultMode) {
            val modes = _newActivityModes.value
            if (mode in modes) setNewActivityModes(modes - mode)
        }

        /** Follows the Zaps Only setting; turning it on drops a Likes dot already lit. */
        @Synchronized
        fun setZapsOnlyMode(on: Boolean) {
            zapsOnlyMode = on
            if (on) markRelayViewed(VaultMode.LIKES)
        }

        /**
         * An event of [kind] arrived from someone else (null: the import line
         * named no kind). Lights the dot on the list it lands in, if any, and
         * ticks the live re-subscribe either way.
         */
        @Synchronized
        fun markInboxActivity(kind: Int?) {
            val landed = kind?.let(VaultMode::listing)?.takeUnless { zapsOnlyMode && it == VaultMode.LIKES }
            if (landed != null && landed !in _newActivityModes.value) {
                setNewActivityModes(_newActivityModes.value + landed)
            }
            _inboxActivityTick.value += 1
        }

        /** Update the displayed event-count stat. Does NOT affect the red dot. */
        fun updateEventsStored(count: Int) {
            _eventsStored.value = count
        }

        /**
         * True once the user's external relay has replaced the embedded one
         * (Advanced > External Relay). Nothing may boot the embedded relay in
         * this mode — not launch, not boot, not the Dashboard buttons.
         */
        @Volatile
        var externalMode = false
            private set

        /** True from onCreate until onDestroy has finished closing the relay. */
        @Volatile
        var serviceAlive = false
            private set

        /**
         * Hand every client to the external relay. There is nothing to boot,
         * so the readiness gates the Feed and Vault wait on open immediately.
         */
        fun useExternalRelay(context: Context) {
            externalMode = true
            stop(context)
            _relayStatus.value = RelayStatus.RUNNING
            _readyForConnections.value = true
        }

        /**
         * What the embedded relay was last started with, set when a boot loads
         * its config and cleared when the service is destroyed. Null means no
         * embedded relay is up, so a settings save has nothing to restart.
         */
        @Volatile
        var launchedInputs: RelayConfiguration.LaunchInputs? = null
            private set

        // Collected only while a service instance exists, so a request made
        // with no service alive cannot create one.
        private val restartRequests = MutableSharedFlow<Unit>(
            extraBufferCapacity = 1,
            onBufferOverflow = BufferOverflow.DROP_OLDEST,
        )
        private val restartsHandled = MutableStateFlow(0L)

        /**
         * Restart the embedded relay in place onto the saved config, if the
         * saved config would start it differently. Suspends until the service
         * has handled the request. Used by [RelayConfigApplier] only; the
         * service re-checks the saved config itself before restarting.
         */
        suspend fun restartForSavedConfig() {
            if (externalMode || !serviceAlive) return
            if (restartRequests.subscriptionCount.value == 0) return
            val before = restartsHandled.value
            restartRequests.tryEmit(Unit)
            withTimeoutOrNull(RESTART_AWAIT_TIMEOUT_MS) {
                restartsHandled.first { it > before }
            } ?: Log.w(TAG, "Settings restart did not finish within ${RESTART_AWAIT_TIMEOUT_MS}ms")
        }

        fun start(context: Context) {
            if (externalMode) return
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
        serviceAlive = true
        // Own the live log poller for the whole service lifetime so the relay-activity
        // red dot is detected continuously (not only while the Dashboard is on-screen).
        // The poll loop idles harmlessly until the Go relay is loaded.
        // Route the relay's NOTIFY marker lines to the local notifier so inbound
        // mentions/DMs/zaps raise system notifications without a push server.
        localNotifier.ensureChannel()
        logStore.notifySink = { line -> localNotifier.onLogLine(line) }
        logStore.startPolling(serviceScope)
        serviceScope.launch {
            restartRequests.collect {
                try {
                    restartRelayInPlace()
                } catch (e: kotlinx.coroutines.CancellationException) {
                    throw e
                } catch (e: Exception) {
                    Log.e(TAG, "Settings restart failed: ${e.message}")
                } finally {
                    restartsHandled.update { it + 1 }
                }
            }
        }
    }

    /**
     * The foreground-service type to start with, matched to what the running
     * platform actually understands.
     *
     * `specialUse` — the type this relay genuinely is — only exists on API 34+.
     * On 29-33 the manifest parser drops it, leaving the service with no
     * declared type while [ServiceCompat] still passes the SPECIAL_USE bit;
     * Android rejects the mismatch with IllegalArgumentException, which the
     * caller catches and turns into a silent OFFLINE + stopSelf. The relay then
     * never starts on Android 10-13 and says nothing about it. `dataSync` is
     * the closest type those releases do understand.
     *
     * Below 29 there is no typed startForeground at all; ServiceCompat ignores
     * the argument, so 0 (NOT_FOREGROUND_SERVICE_TYPE) is correct.
     */
    private fun foregroundServiceType(): Int = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE ->
            ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q ->
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        else -> 0
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }

        try {
            // ServiceCompat drops the type argument below API 29, where the
            // 3-arg Service#startForeground doesn't exist (calling it directly
            // throws NoSuchMethodError, which the catch below wouldn't catch).
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                buildNotification(RelayStatus.BOOTING),
                foregroundServiceType(),
            )
        } catch (e: Exception) {
            Log.e(TAG, "startForeground failed: ${e.message}")
            if (!externalMode) _relayStatus.value = RelayStatus.OFFLINE
            stopSelf()
            return START_NOT_STICKY
        }

        // A START_STICKY restart can arrive before MainActivity has read the
        // config, so the service checks the mode itself. startForeground has
        // already run above, which is what a startForegroundService caller
        // requires before the service may stop.
        if (externalMode || loadSavedConfig().useExternalRelay) {
            Log.i(TAG, "External relay mode -- not starting the embedded relay")
            externalMode = true
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
        // In external mode these describe the external relay, which is still up.
        if (!externalMode) {
            _relayStatus.value = RelayStatus.OFFLINE
            _readyForConnections.value = false
        }

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
        launchedInputs = null

        // Release resources only after the Go side has stopped (or timed out)
        releaseWakeLock()
        serviceScope.cancel()
        serviceAlive = false
        super.onDestroy()
    }

    /** Load saved config from disk (matches ConfigStore persistence path). */
    private fun loadSavedConfig(): HavenConfig {
        val configFile = File(filesDir, "nostrvault_config.json")
        if (!configFile.exists()) {
            Log.w(TAG, "No config file found, using defaults")
            return HavenConfig()
        }
        return try {
            jsonCodec.decodeFromString<HavenConfig>(configFile.readText())
        } catch (e: Exception) {
            Log.w(TAG, "Failed to parse config, using defaults: ${e.message}")
            HavenConfig()
        }
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

    // ── Settings restart ───────────────────────────────────────────

    /**
     * Restart the Go relay in place (the service, its foreground notification
     * and wake lock stay up) when the saved config would start it differently
     * from what it is running. Waits out a boot in progress first; a relay
     * that is stopped or retrying needs nothing, as its next start reads the
     * saved config from disk.
     */
    private suspend fun restartRelayInPlace() {
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

    // ── Health watchdog ────────────────────────────────────────────

    /**
     * Periodically probe the relay's TCP port while in RUNNING state.
     * If 3 consecutive probes fail, assume the Go side has died and
     * trigger a restart cycle.
     */
    private fun startHealthWatchdog() {
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
            .setSmallIcon(R.drawable.ic_notification)
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
