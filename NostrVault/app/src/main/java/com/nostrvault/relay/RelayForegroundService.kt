package com.nostrvault.relay

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.ServiceCompat
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
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import java.io.File

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

        internal const val TAG = "RelayService"
        internal const val ACTION_STOP = "com.nostrvault.relay.STOP"
        internal const val WAKELOCK_TAG = "NostrVault::RelayWakeLock"

        internal const val MAX_RETRY_ATTEMPTS = 3
        internal val RETRY_DELAYS_MS = longArrayOf(2_000, 5_000, 10_000)
        // A refused localhost connect fails at once, so polling often costs
        // nothing and the feed hears "ready" soon after the relay listens.
        internal const val HEALTH_CHECK_INTERVAL_MS = 100L
        internal const val HEALTH_CHECK_TIMEOUT_MS = 15_000L
        internal const val SHUTDOWN_TIMEOUT_MS = 5_000L
        private const val CRASH_RESTART_WINDOW_MS = 30_000L
        private const val CRASH_RESTART_DELAY_MS = 3_000L
        internal const val PREFS_NAME = "relay_lifecycle"
        internal const val PREF_WATCHDOG_RESTARTS = "watchdog_restarts"
        internal const val PREF_LAST_START_TIME = "last_start_time"

        internal const val WATCHDOG_INTERVAL_MS = 30_000L   // check every 30s
        internal const val WATCHDOG_PROBE_TIMEOUT_MS = 2_000 // TCP probe timeout
        internal const val WATCHDOG_MAX_FAILURES = 3         // consecutive failures before restart

        /** How long a settings restart waits for an in-progress boot to settle. */
        internal const val RESTART_BOOT_SETTLE_TIMEOUT_MS = 60_000L
        /** How long [restartForSavedConfig] waits for the service to finish. */
        private const val RESTART_AWAIT_TIMEOUT_MS = 120_000L

        internal val _relayStatus = MutableStateFlow(RelayStatus.OFFLINE)
        val relayStatus: StateFlow<RelayStatus> = _relayStatus.asStateFlow()

        private val _eventsStored = MutableStateFlow(0)
        val eventsStored: StateFlow<Int> = _eventsStored.asStateFlow()

        private val _connections = MutableStateFlow(0)
        val connections: StateFlow<Int> = _connections.asStateFlow()

        /** Feed connections should wait until this is true (3s after RUNNING). */
        internal val _readyForConnections = MutableStateFlow(false)
        val readyForConnections: StateFlow<Boolean> = _readyForConnections.asStateFlow()

        // ── Error states (surfaced from RelayLogParser) ────────
        private val _isLocked = MutableStateFlow(false)
        val isLocked: StateFlow<Boolean> = _isLocked.asStateFlow()

        private val _isPortConflict = MutableStateFlow(false)
        val isPortConflict: StateFlow<Boolean> = _isPortConflict.asStateFlow()

        /** The relay's open websocket connections, polled by [LogStore]. */
        fun updateConnections(count: Int) {
            _connections.value = count.coerceAtLeast(0)
        }

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
            // The Vault list shows everything, so seeing it sees every list.
            if (mode == VaultMode.ACTIVITY) {
                if (_newActivityModes.value.isNotEmpty()) setNewActivityModes(emptySet())
                return
            }
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
            internal set

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
            // No relay and no notification before setup is finished: the
            // setup import's cleanup and the boot receiver both got here on
            // a setup that was left half-way. Setup's last step starts it.
            val config = EntryPointAccessors
                .fromApplication(context.applicationContext, BootCompletedReceiver.BootReceiverEntryPoint::class.java)
                .configStore().config.value
            if (!config.hasCompletedSetup) {
                Log.i(TAG, "Setup not finished; not starting the relay")
                return
            }
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
        fun accountUnread(): com.nostrvault.data.local.AccountUnreadStore
        fun fipsMeshManager(): com.nostrvault.fips.FipsMeshManager
    }

    // ── Lifecycle state machine (replaces bare `relayStarted` boolean) ──

    internal enum class LifecycleState { IDLE, BOOTING, RUNNING, STOPPING }

    @Volatile private var state = LifecycleState.IDLE

    /** Every change re-decides the wake lock ([RelayWakeLockPolicy]). */
    internal var lifecycleState: LifecycleState
        get() = state
        set(value) {
            state = value
            syncWakeLock()
        }

    /** The mesh is up and offers this relay to peers; see [RelayWakeLockPolicy]. */
    @Volatile internal var servingMesh = false
    @Volatile internal var isShuttingDown = false
    internal var retryCount = 0
    /** When the health watchdog restarted the relay ([WatchdogRestartPolicy]). */
    internal val watchdogRestarts = mutableListOf<Long>()
    internal var currentRelayPort = 3355

    internal val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val jsonCodec = Json { ignoreUnknownKeys = true; prettyPrint = true }
    internal var wakeLock: PowerManager.WakeLock? = null
    internal var healthWatchdogJob: Job? = null

    private val logStore: LogStore by lazy {
        EntryPointAccessors.fromApplication(applicationContext, LogStoreEntryPoint::class.java).logStore()
    }

    private val localNotifier: com.nostrvault.service.LocalNotificationService by lazy {
        EntryPointAccessors.fromApplication(applicationContext, LogStoreEntryPoint::class.java).localNotifier()
    }

    /**
     * The mesh comes back with the relay, so a reboot brings both back without the app being
     * opened: BootCompletedReceiver loads the config and starts this service, and this runs once
     * the relay answers. A no-op when the mesh is off, already running, or the config is not
     * loaded yet (a sticky restart in a fresh process: the mesh then starts with the app).
     */
    internal fun restoreMesh() {
        EntryPointAccessors.fromApplication(applicationContext, LogStoreEntryPoint::class.java)
            .fipsMeshManager()
            .restoreIfEnabled(serviceScope)
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
        // The same markers count each account's new notifications for the switcher.
        val accountUnread = EntryPointAccessors.fromApplication(applicationContext, LogStoreEntryPoint::class.java).accountUnread()
        logStore.notifySink = { line ->
            localNotifier.onLogLine(line)
            accountUnread.onLogLine(line)
        }
        logStore.quietKinds = accountUnread::ownAccountOnlyKinds
        logStore.startPolling(serviceScope)
        val mesh = EntryPointAccessors.fromApplication(applicationContext, LogStoreEntryPoint::class.java).fipsMeshManager()
        serviceScope.launch {
            combine(mesh.status, mesh.shareRelay) { status, share -> status.running && share }
                .distinctUntilChanged()
                .collect {
                    servingMesh = it
                    syncWakeLock()
                }
        }
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
        // Someone started the relay: the watchdog's restart count starts over.
        // A START_STICKY restart (null intent) is the system, not someone.
        val stickyWait = if (intent != null) {
            clearWatchdogRestarts()
            0L
        } else {
            stickyRestartWait(CRASH_RESTART_WINDOW_MS)
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
        if (stickyWait == null) {
            Log.e(TAG, "Relay restarted itself ${WatchdogRestartPolicy.MAX_RESTARTS} times in 6 h — leaving it offline until the app starts it")
            _relayStatus.value = RelayStatus.OFFLINE
            stopSelf()
            return START_NOT_STICKY
        }
        syncWakeLock()

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
            if (stickyWait > 0) {
                Log.w(TAG, "Crash-loop restart, waiting ${stickyWait / 1000}s first")
                delay(stickyWait)
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
        _connections.value = 0 // the poller that kept it current died with the scope
        serviceAlive = false
        super.onDestroy()
    }

    /** Load saved config from disk (matches ConfigStore persistence path). */
    internal fun loadSavedConfig(): HavenConfig {
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
}
