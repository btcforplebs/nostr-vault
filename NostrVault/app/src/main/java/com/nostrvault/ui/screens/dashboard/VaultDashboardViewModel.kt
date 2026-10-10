package com.nostrvault.ui.screens.dashboard

import android.content.Context
import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.local.CredentialStore
import com.nostrvault.data.local.VaultHistory
import com.nostrvault.data.local.VaultHistoryStore
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.HavenConfig
import com.nostrvault.relay.MacSync
import com.nostrvault.relay.MacSyncStatus
import com.nostrvault.relay.PublicRelayList
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.relay.RelayMatrix
import com.nostrvault.service.FeedService
import com.nostrvault.service.FollowingBackupService
import com.nostrvault.service.NostrService
import com.nostrvault.service.StatsService
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import javax.inject.Inject

/**
 * State behind the Vault Dashboard (v2) that the Vault tab's own view model
 * doesn't hold: the safety checks, who can reach you, the tile counts and the
 * "last ran" history. Port of the data half of iOS `VaultDashboardView`.
 */
@HiltViewModel
class VaultDashboardViewModel @Inject constructor(
    @ApplicationContext private val context: Context,
    val configStore: ConfigStore,
    val statsService: StatsService,
    private val nostrService: NostrService,
    private val feedService: FeedService,
    private val followingBackupService: FollowingBackupService,
    private val historyStore: VaultHistoryStore,
) : ViewModel() {

    private companion object {
        const val TAG = "VaultDashboardVM"
        /** RelayForegroundService's lifecycle prefs: when the relay last started. */
        const val RELAY_PREFS = "relay_lifecycle"
        const val RELAY_LAST_START = "last_start_time"
    }

    val history: StateFlow<VaultHistory.Snapshot> = historyStore.state
    val wotPubkeys: StateFlow<Set<String>> = feedService.wotPubkeys
    val kindCounts: StateFlow<Map<Int, Int>> = statsService.kindCounts

    /** Blobs the vault's Blossom server holds for you; null until the relay answers. */
    private val _mediaCount = MutableStateFlow<Int?>(null)
    val mediaCount: StateFlow<Int?> = _mediaCount.asStateFlow()

    private val _macSync = MutableStateFlow<MacSyncStatus?>(null)
    val macSync: StateFlow<MacSyncStatus?> = _macSync.asStateFlow()

    /** When the active account's follow list was last saved (epoch ms); null for never. */
    private val _followListSavedAt = MutableStateFlow<Long?>(null)
    val followListSavedAt: StateFlow<Long?> = _followListSavedAt.asStateFlow()

    private val _hasLocalKey = MutableStateFlow(false)
    val hasLocalKey: StateFlow<Boolean> = _hasLocalKey.asStateFlow()

    private val _relayStartedAt = MutableStateFlow<Long?>(null)
    val relayStartedAt: StateFlow<Long?> = _relayStartedAt.asStateFlow()

    private var counting = false

    init {
        viewModelScope.launch {
            // The follow list backup is written by FeedService; follow it live.
            followingBackupService.snapshots.collect { refreshFollowList() }
        }
        viewModelScope.launch {
            RelayForegroundService.relayStatus.collect { status ->
                readRelayStart()
                if (status == RelayForegroundService.RelayStatus.RUNNING) refresh()
            }
        }
        viewModelScope.launch {
            // A new account means a different key, follow list and media.
            configStore.config.collect { refreshLocal(it) }
        }
    }

    /** Re-reads everything; counts only while the relay is up (iOS refresh()). */
    fun refresh() {
        statsService.refreshStats()
        refreshLocal(configStore.config.value)
        refreshFollowList()
        readRelayStart()
        if (RelayForegroundService.relayStatus.value != RelayForegroundService.RelayStatus.RUNNING) return
        if (counting) return
        counting = true
        viewModelScope.launch {
            try {
                statsService.fetchCountsByKind()
                val owner = nostrService.activeHexPubkey
                if (owner.isNotEmpty()) {
                    _mediaCount.value = runCatching { statsService.fetchBlobList(owner).size }
                        .onFailure { Log.w(TAG, "Blob list failed: ${it.message}") }
                        .getOrNull() ?: _mediaCount.value
                }
            } finally {
                counting = false
            }
        }
    }

    /** The light pull-to-refresh: ask the relay to top up, then re-read (never a full import). */
    fun pullToRefresh() {
        if (RelayForegroundService.relayStatus.value == RelayForegroundService.RelayStatus.RUNNING) {
            runCatching { HavenBridge.requestRelaySync() }
                .onFailure { Log.w(TAG, "requestRelaySync failed: ${it.message}") }
        }
        refresh()
    }

    private fun refreshLocal(cfg: HavenConfig) {
        viewModelScope.launch {
            val (mac, key) = withContext(Dispatchers.IO) {
                val dir = cfg.relayDataDir?.let(::File) ?: File(context.filesDir, "relay_data")
                MacSync.read(dir) to localKeyFor(cfg)
            }
            _macSync.value = mac
            _hasLocalKey.value = key
        }
    }

    private fun refreshFollowList() {
        val npub = activeNpub(configStore.config.value)
        _followListSavedAt.value = runCatching { followingBackupService.snapshotsFor(npub) }
            .getOrDefault(emptyList())
            .maxOfOrNull { it.capturedAt }
    }

    private fun readRelayStart() {
        val running = RelayForegroundService.relayStatus.value == RelayForegroundService.RelayStatus.RUNNING
        _relayStartedAt.value = if (running) {
            context.getSharedPreferences(RELAY_PREFS, Context.MODE_PRIVATE).getLong(RELAY_LAST_START, 0L).takeIf { it > 0 }
        } else {
            null
        }
    }

    /** Same test as Settings › Accounts (AccountSettingsViewModel.hasLocalKey). */
    private fun localKeyFor(cfg: HavenConfig): Boolean = runCatching {
        val npub = activeNpub(cfg)
        if (npub.isEmpty()) return@runCatching false
        val hex = HavenBridge.decodeNpub(npub).orEmpty()
        val nsec = hex.isNotEmpty() && CredentialStore.getNsec(hex) != null
        if (npub == cfg.ownerNpub) {
            cfg.ownerHexKey != null || cfg.ownerNcryptsec != null || nsec
        } else {
            CredentialStore.getCredentialHexKey(npub) != null || nsec
        }
    }.getOrDefault(false)

    // ── Derived from config ─────────────────────────────────────

    fun activeNpub(cfg: HavenConfig): String = cfg.activeOrOwnerNpub()

    /** A remote signer (NIP-46 bunker) or a signer app (Amber) holds the key. */
    fun usesSigner(cfg: HavenConfig): Boolean = when (cfg.activeSigningMode()) {
        "nip46" -> cfg.bunkerConfig(activeNpub(cfg)) != null
        "amber" -> true
        else -> false
    }

    /**
     * The vault's own addresses that would go in the published relay list.
     * Empty for a pocket relay with no Mac relay: there is nothing to list.
     */
    fun hasPublishableOwnRelay(cfg: HavenConfig): Boolean =
        PublicRelayList.tags(ownRelays = listOf(cfg.macRelayWssURL), read = emptyList(), write = emptyList()).isNotEmpty()

    fun publishesRelayList(cfg: HavenConfig): Boolean = cfg.publishRelayListPerAccount[activeNpub(cfg)] == true

    fun publishRelayList() {
        val npub = activeNpub(configStore.config.value)
        if (npub.isEmpty()) return
        configStore.setPublishRelayList(npub, true)
        nostrService.publishRelayList(npub)
    }

    /**
     * Counted the way Settings › Relays counts its "N relays" chip, so the
     * two never disagree: every relay in any column, plus your own.
     */
    fun relayCount(cfg: HavenConfig): Int {
        val ownRelay = cfg.macRelayWssURL
        val rows = RelayMatrix.rows(RelayMatrix.lists(cfg), listOf(ownRelay, cfg.ownHavenDMInboxURL))
        return rows.size + if (ownRelay.isEmpty()) 0 else 1
    }

    fun setAutoStart(enabled: Boolean) = configStore.update { it.copy(autoStartRelay = enabled) }
}
