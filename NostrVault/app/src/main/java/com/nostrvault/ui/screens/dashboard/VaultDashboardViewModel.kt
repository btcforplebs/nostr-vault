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
import com.nostrvault.service.MediaCacheService
import com.nostrvault.service.NostrService
import com.nostrvault.service.StatsService
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import javax.inject.Inject

/**
 * State behind the Vault Dashboard (v2) that the Vault tab's own view model
 * doesn't hold: the safety checks, who can reach you, what is in the vault
 * and the "last ran" history. Port of the data half of iOS
 * `VaultDashboardView` and `VaultContentsModel`.
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
    private val mediaCacheService: MediaCacheService,
    private val notificationManager: com.nostrvault.ui.notification.NotificationManager,
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
    /**
     * The active account's own counts per kind; null when the last "yours"
     * count belongs to another account (or none has run), so no "yours" shows.
     */
    val yourKindCounts: StateFlow<Map<Int, Int>?> = combine(
        statsService.yourKindCounts,
        configStore.activeAccountHexPubkey,
        configStore.config,
    ) { yours, _, _ ->
        yours?.takeIf { it.author == nostrService.activeHexPubkey }?.byKind
    }.stateIn(viewModelScope, SharingStarted.Eagerly, null)
    /** Every event in the vault: the `{}` COUNT summed over its relays. */
    val totalEvents: StateFlow<Int> = statsService.loadedEventsCount

    private val _isCounting = MutableStateFlow(false)
    val isCounting: StateFlow<Boolean> = _isCounting.asStateFlow()

    /** The last count did not get an answer from every relay; the old numbers stay up. */
    private val _countFailed = MutableStateFlow(false)
    val countFailed: StateFlow<Boolean> = _countFailed.asStateFlow()

    /** The owner has no key, so /private and /chat are left out of the counts. */
    val countsPublicOnly: StateFlow<Boolean> = configStore.config
        .map { statsService.ownerIsWatchOnly(it) }
        .stateIn(viewModelScope, SharingStarted.Eagerly, statsService.ownerIsWatchOnly(configStore.config.value))

    /** The files in the Blossom folder, by type; null until scanned. */
    private val _media = MutableStateFlow<VaultDashboardContents.Media?>(null)
    internal val media: StateFlow<VaultDashboardContents.Media?> = _media.asStateFlow()

    /** The media cache (MediaCacheService's folders), by type; null until scanned. */
    data class Cache(val images: Pair<Int, Long>, val videos: Pair<Int, Long>, val thumbnails: Pair<Int, Long>, val other: Pair<Int, Long>) {
        val bytes: Long get() = images.second + videos.second + thumbnails.second + other.second
        val isEmpty: Boolean get() = images.first + videos.first + thumbnails.first + other.first == 0
    }

    private val _cache = MutableStateFlow<Cache?>(null)
    val cache: StateFlow<Cache?> = _cache.asStateFlow()

    private val _isClearingCache = MutableStateFlow(false)
    val isClearingCache: StateFlow<Boolean> = _isClearingCache.asStateFlow()

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
        loadFiles()
        if (RelayForegroundService.relayStatus.value != RelayForegroundService.RelayStatus.RUNNING) return
        if (counting) return
        counting = true
        _isCounting.value = true
        viewModelScope.launch {
            try {
                val owner = nostrService.activeHexPubkey.ifEmpty { null }
                // A partial answer would undercount; StatsService keeps what is shown.
                _countFailed.value = !statsService.fetchCountsByKind(owner, VaultDashboardContents.yourKinds)
            } finally {
                counting = false
                _isCounting.value = false
            }
        }
    }

    /** The Blossom folder and the media cache, sized and typed by their bytes. */
    fun loadFiles() {
        viewModelScope.launch {
            val cfg = configStore.config.value
            val (media, cache) = withContext(Dispatchers.IO) {
                val blossom = cfg.relayDataDir?.let { File(it, cfg.blossomPath) }
                scanMedia(blossom) to scanCache()
            }
            _media.value = media
            _cache.value = cache
        }
    }

    /** The same files the media grid lists (MediaGalleryViewModel.loadLocalBlossomFiles). */
    private fun scanMedia(dir: File?): VaultDashboardContents.Media {
        val counts = HashMap<VaultDashboardContents.MediaType, Pair<Int, Long>>()
        dir?.listFiles()?.forEach { file ->
            if (!file.isFile || !VaultDashboardContents.isListedBlob(file.nameWithoutExtension)) return@forEach
            val type = VaultDashboardContents.mediaType(readHeader(file))
            val (n, bytes) = counts[type] ?: (0 to 0L)
            counts[type] = n + 1 to bytes + file.length()
        }
        return VaultDashboardContents.Media(
            VaultDashboardContents.MediaType.entries.map { t ->
                val (n, bytes) = counts[t] ?: (0 to 0L)
                VaultDashboardContents.MediaBucket(t, n, bytes)
            },
        )
    }

    private fun readHeader(file: File): ByteArray = runCatching {
        file.inputStream().use { input ->
            val buf = ByteArray(16)
            val n = input.read(buf)
            if (n <= 0) ByteArray(0) else buf.copyOf(n)
        }
    }.getOrDefault(ByteArray(0))

    private fun scanCache(): Cache {
        val media = statsService.calculateCacheBreakdown(mediaCacheService.cacheDirectory.path)
        val thumbs = mediaCacheService.thumbnailDirectory.walkTopDown().filter { it.isFile }.toList()
        return Cache(
            images = media.imageCount to media.imageSize,
            videos = media.videoCount to media.videoSize,
            thumbnails = thumbs.size to thumbs.sumOf { it.length() },
            other = media.otherCount to media.otherSize,
        )
    }

    /** Clears other people's media kept for quick loading; your own Blossom files stay. */
    fun clearCache() {
        if (_isClearingCache.value) return
        _isClearingCache.value = true
        viewModelScope.launch {
            try {
                val result = withContext(Dispatchers.IO) { mediaCacheService.clearCache() }
                val freed = VaultDashboardModel.size(result.bytesFreed).let { if (it == "None") "0 B" else it }
                if (result.filesFailed == 0) {
                    notificationManager.showToast("Cleared $freed of temporary copies")
                } else {
                    notificationManager.showError(
                        "Cleared $freed, but ${result.filesFailed} files could not be removed",
                        style = com.nostrvault.ui.notification.ErrorStyle.WARNING,
                    )
                }
                _cache.value = withContext(Dispatchers.IO) { scanCache() }
            } finally {
                _isClearingCache.value = false
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
