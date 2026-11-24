package com.nostrvault.relay

import android.util.Log
import com.nostrvault.fips.FipsBridge
import com.nostrvault.fips.FipsIngress
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Dialing the mesh desktop Vaults (Desktop Vaults P6, PLANS/NV_DESKTOP_VAULTS_PLAN.md §2.2 rule 3): the first that
 * answers in Desktop Vaults order becomes MAC_RELAY_URL's local ws:// address and the publish-for-me target
 * ([RelayConfiguration.macMeshRelay]). iOS twin: `RelayProcessManager+Start.swift` (P3 #2506, F1 #2507).
 *
 * [dial] runs before a start, only when the slot itself is a mesh npub. Every other mesh Vault is dialed by
 * [afterStart] once the relay is up over wss, so a paired Mac out of reach never holds a start (Tron M1 on #2506).
 */
object MeshVaultDial {
    private const val TAG = "MeshVaultDial"
    private const val NODE_POLL_MS = 500L

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** One background dial at a time. */
    @Volatile private var background: Job? = null

    /** The list the last background dial found nobody on, and when: a save doesn't dial it again for a while. */
    @Volatile private var failed: Pair<List<String>, Long>? = null

    /** How long a save waits before dialing a list that just found nobody again. A start always dials. */
    const val RETRY_AFTER_SAVE_MS = 5 * 60_000L

    /**
     * The first of [npubs] that answers. Waits up to [RelayConfiguration.MESH_NODE_WAIT_MS] for the mesh node (the
     * app starts it on open, possibly after the relay) by dialing the first; the rest share one
     * [DesktopVaultsRules.MESH_DIAL_BUDGET_MS]. Blocks.
     */
    fun dial(
        npubs: List<String>,
        dial: (String) -> FipsIngress = FipsBridge::ingress,
        pause: (Long) -> Unit = Thread::sleep,
    ): RelayConfiguration.MacMeshRelay? {
        val first = npubs.firstOrNull() ?: return null
        var ingress = dial(first)
        var waited = 0L
        while (ingress.error == FipsBridge.ERR_NOT_RUNNING && waited < RelayConfiguration.MESH_NODE_WAIT_MS) {
            pause(NODE_POLL_MS)
            waited += NODE_POLL_MS
            ingress = dial(first)
        }
        val found = ingress.url?.let(RelayConfiguration::meshWebsocketURL)?.let { first to it }
            ?: DesktopVaultsRules.firstAnswering(npubs.drop(1), DesktopVaultsRules.MESH_DIAL_BUDGET_MS) { npub ->
                dial(npub).url?.let(RelayConfiguration::meshWebsocketURL)
            }
        if (found == null) {
            Log.w(TAG, "No mesh desktop Vault answered (${npubs.size} dialed); starting without one")
            return null
        }
        Log.i(TAG, "Desktop Vault reached over the mesh (${found.first.take(16)}…)")
        return RelayConfiguration.MacMeshRelay(found.first, found.second)
    }

    /**
     * The relay is up over wss: dial the mesh Vaults now and restart once one answers, so it moves to the mesh. The
     * restart goes straight to [RelayForegroundService.restartForSavedConfig], skipping the settings applier's gap
     * (Tron F1 on #2506: after a settings restart the dial answers within seconds and the move was lost). It can't
     * loop: it runs only while the relay holds no mesh Vault, and the start it causes takes the hand-over. Nothing
     * with FIPS off, with no mesh Vault, for a mesh-npub slot (dialed before the start), with no relay running or
     * while a dial runs. Called after each start and each config save (Mesh turned on, a Mac paired), since a save
     * no longer dials ([RelayConfiguration.comparedInputs]).
     *
     * [latest]: the saved config when the dial ends; the hand-over is dropped when the relay stopped or the Vault
     * left the list meanwhile.
     */
    fun afterStart(
        config: HavenConfig,
        latest: () -> HavenConfig,
        fromSave: Boolean = false,
        now: () -> Long = System::currentTimeMillis,
        relayRunning: () -> Boolean = { RelayForegroundService.launchedInputs != null },
        restart: suspend () -> Unit = { RelayForegroundService.restartForSavedConfig() },
        ingress: (String) -> FipsIngress = FipsBridge::ingress,
    ): Job? {
        val npubs = config.desktopVaultMeshNpubs
        if (DesktopVaultsRules.meshDial(config.fipsMeshEnabled, config.macRelayURL, npubs) != DesktopVaultsRules.MeshDial.AFTER_START) return null
        if (RelayConfiguration.macMeshRelay != null || !relayRunning()) return null
        // Saves come often: an unreachable list is dialed again on the next start, or after a while.
        failed?.let { (list, at) -> if (fromSave && list == npubs && now() - at < RETRY_AFTER_SAVE_MS) return null }
        synchronized(this) {
            if (background?.isActive == true) return null
            return scope.launch {
                val found = dial(npubs, ingress)
                failed = if (found == null) npubs to now() else null
                if (found == null) return@launch
                val now = latest()
                if (!relayRunning() || RelayConfiguration.macMeshRelay != null || found.npub !in now.desktopVaultMeshNpubs) return@launch
                RelayConfiguration.pendingMeshRelay = found
                restart()
                RelayConfiguration.droppingUnusedHandOver(found)
            }.also { background = it }
        }
    }
}
