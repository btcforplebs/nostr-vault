package com.nostrvault.data.local

import android.content.Context
import com.nostrvault.relay.AccountBunkerConfig
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.HavenConfig
import com.nostrvault.relay.RelayConfigApplier
import com.nostrvault.relay.RelayConfiguration
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.service.NIP46Service
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Port of ConfigService.swift persistence layer.
 * Uses JSON file persistence (matching iOS approach) with StateFlow
 * for reactive config updates.
 *
 * Complex config properties (relay URLs, account management, etc.) are
 * stored in HavenConfig and serialized to config.json.
 */
@Singleton
class ConfigStore @Inject constructor(
    @ApplicationContext private val context: Context,
) {
    private val json = Json { ignoreUnknownKeys = true; prettyPrint = true }
    private val configFile get() = File(context.filesDir, "nostrvault_config.json")

    private val _config = MutableStateFlow(HavenConfig())
    val config: StateFlow<HavenConfig> = _config.asStateFlow()

    private val _activeAccountHexPubkey = MutableStateFlow("")
    val activeAccountHexPubkey: StateFlow<String> = _activeAccountHexPubkey.asStateFlow()

    private val _isSwitchingAccount = MutableStateFlow(false)
    val isSwitchingAccount: StateFlow<Boolean> = _isSwitchingAccount.asStateFlow()

    /**
     * Restarts the embedded relay after a save that changes how it would
     * start; every other save is a no-op for it. Lives here, at the one place
     * config is saved, so no settings screen needs a "restart to apply" step.
     */
    val relayApplier = RelayConfigApplier(
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
        now = { android.os.SystemClock.elapsedRealtime() },
        launchedInputs = { RelayForegroundService.launchedInputs },
        inputsFor = { RelayConfiguration.launchInputs(it, File(context.filesDir, "relay_data")) },
        restart = { RelayForegroundService.restartForSavedConfig() },
    )

    /** Load config from disk or create defaults. */
    fun reload() {
        var loaded = try {
            if (configFile.exists()) {
                json.decodeFromString<HavenConfig>(configFile.readText())
            } else {
                HavenConfig()
            }
        } catch (_: Exception) {
            HavenConfig()
        }

        // Ensure runtime paths are always populated — these are derived from the
        // app's filesystem and intentionally not persisted, but every service that
        // reads config.relayDataDir depends on them being present.
        val relayDir = File(context.filesDir, "relay_data")
        loaded = loaded.copy(
            relayDataDir = relayDir.absolutePath,
            appSupportDir = context.filesDir.absolutePath,
        )

        // Drop former default mirrors that no longer exist (kylezien is NXDOMAIN,
        // satellite's CDN is dead — verified 2026-07). Configs written by old
        // builds may still carry them; they fail every upload and add timeout
        // latency to every post.
        val defunctMirrorHosts = listOf("blossom.kylezien.com", "cdn.satellite.earth")
        val liveMirrors = loaded.blossomMirrors.filterNot { mirror ->
            defunctMirrorHosts.any { mirror.contains(it, ignoreCase = true) }
        }
        if (liveMirrors.size != loaded.blossomMirrors.size) {
            loaded = loaded.copy(blossomMirrors = liveMirrors)
        }

        // Multi-account migration: seed the owner's signing mode so
        // activeSigningMode() is stable for legacy single-owner configs. The
        // owner is synthesized by allAccountNpubs(), so it is NOT added to
        // accountNpubs (which is the non-owner roster). whitelistedNpubs is the
        // relay/follow list and is intentionally never migrated here.
        if (loaded.ownerNpub.isNotEmpty() && loaded.ownerNpub !in loaded.accountSigningModes) {
            loaded = loaded.copy(
                accountSigningModes = loaded.accountSigningModes + (loaded.ownerNpub to loaded.signingMode),
            )
        }

        _config.value = loaded

        // Restore active account hex pubkey from persisted ownerNpub so that
        // profile navigation works on subsequent app launches (not just setup).
        if (_activeAccountHexPubkey.value.isEmpty()) {
            val npub = _config.value.ownerNpub
            if (npub.startsWith("npub1")) {
                HavenBridge.decodeNpub(npub)?.let { hex ->
                    _activeAccountHexPubkey.value = hex
                }
            }
        }
    }

    /** Persist current config to disk. */
    suspend fun save() = withContext(Dispatchers.IO) {
        try {
            configFile.writeText(json.encodeToString(_config.value))
        } catch (_: Exception) { }
    }

    /** Update config and auto-save (suspend). */
    suspend fun updateAsync(transform: (HavenConfig) -> HavenConfig) {
        _config.value = transform(_config.value)
        save()
        relayApplier.configSaved(_config.value)
    }

    /** Update config synchronously (saves in background). */
    fun update(transform: (HavenConfig) -> HavenConfig) {
        _config.value = transform(_config.value)
        kotlinx.coroutines.CoroutineScope(Dispatchers.IO).launch {
            save()
            // After the write: the relay re-reads the config from disk.
            relayApplier.configSaved(_config.value)
        }
    }

    /** Set active account pubkey. */
    fun setActiveAccount(hexPubkey: String) {
        _activeAccountHexPubkey.value = hexPubkey
    }

    fun setSwitchingAccount(switching: Boolean) {
        _isSwitchingAccount.value = switching
    }

    // ── Blocked / throttle (per active-or-owner account) ──────────────
    // Mirror of iOS ConfigService.blockProfile/unblockProfile/throttleProfile/
    // unthrottleProfile. These mutate config only; callers that want the change
    // reflected on the network should publish the kind-10000 mute list afterwards.

    /** Block an npub for the active account. No-op if already blocked. */
    fun blockProfile(npub: String) {
        update { cfg ->
            val key = cfg.activeOrOwnerNpub()
            val current = cfg.blockedNpubsPerAccount[key] ?: cfg.blockedNpubs ?: emptyList()
            if (npub in current) cfg
            else cfg.copy(
                blockedNpubsPerAccount = cfg.blockedNpubsPerAccount + (key to (current + npub)),
            )
        }
    }

    /** Unblock an npub for the active account. */
    fun unblockProfile(npub: String) {
        update { cfg ->
            val key = cfg.activeOrOwnerNpub()
            val current = cfg.blockedNpubsPerAccount[key] ?: cfg.blockedNpubs ?: emptyList()
            cfg.copy(
                blockedNpubsPerAccount = cfg.blockedNpubsPerAccount + (key to current.filter { it != npub }),
            )
        }
    }

    /** Throttle an npub to at most [maxPosts] visible posts (1..20). Local-only. */
    fun throttleProfile(npub: String, maxPosts: Int) {
        update { cfg ->
            val key = cfg.activeOrOwnerNpub()
            val current = cfg.throttledAccountsPerAccount[key] ?: emptyMap()
            cfg.copy(
                throttledAccountsPerAccount = cfg.throttledAccountsPerAccount +
                    (key to (current + (npub to maxPosts.coerceIn(1, 20)))),
            )
        }
    }

    /** Remove a throttle limit for an npub. */
    fun unthrottleProfile(npub: String) {
        update { cfg ->
            val key = cfg.activeOrOwnerNpub()
            val current = cfg.throttledAccountsPerAccount[key] ?: return@update cfg
            cfg.copy(
                throttledAccountsPerAccount = cfg.throttledAccountsPerAccount + (key to (current - npub)),
            )
        }
    }

    // ── Multi-account management ──────────────────────────────────────
    // Mirrors iOS ConfigService account handling. The owner is account[0]
    // (synthesized by HavenConfig.allAccountNpubs()); accountNpubs holds the
    // additional accounts. NIP-46 uses a single Go bunker session, so switching
    // disconnects the previous account's signer and reconnects the new one.

    /**
     * Switch the active account. Pass null/empty/owner-npub to return to the
     * owner. Updates both activeAccountNpub and the active hex pubkey flow
     * (fixing the prior desync where guests stayed view-only), and reconnects
     * the NIP-46 bunker if the target account uses remote signing.
     */
    suspend fun switchActiveAccount(npub: String?) {
        val cfg = _config.value
        val target = (npub ?: "").trim()
        val newValue = if (target == cfg.ownerNpub) "" else target
        val currentActive = cfg.activeAccountNpub?.trim().orEmpty()
        if (newValue == currentActive) return

        val prevNpub = cfg.activeOrOwnerNpub()
        if (cfg.bunkerConfig(prevNpub) != null && NIP46Service.isConnected.value) {
            NIP46Service.disconnect()
        }

        setSwitchingAccount(true)
        try {
            updateAsync { it.copy(activeAccountNpub = newValue.ifEmpty { null }) }

            val resolvedNpub = newValue.ifEmpty { cfg.ownerNpub }
            _activeAccountHexPubkey.value =
                if (resolvedNpub.startsWith("npub1")) HavenBridge.decodeNpub(resolvedNpub) ?: "" else ""

            val newCfg = _config.value
            if (newCfg.activeSigningMode() == "nip46") {
                newCfg.bunkerConfig(newCfg.activeOrOwnerNpub())?.let {
                    // Checked against the account: a signer answering as any
                    // other key is dropped, never kept as connected.
                    NIP46Service.connectForAccount(it, _activeAccountHexPubkey.value)
                }
            }
        } finally {
            setSwitchingAccount(false)
        }
    }

    fun addAccount(npub: String) = update { cfg ->
        if (npub.isEmpty() || npub == cfg.ownerNpub || npub in cfg.accountNpubs) cfg
        else cfg.copy(accountNpubs = cfg.accountNpubs + npub)
    }

    fun removeAccount(npub: String) = update { cfg ->
        cfg.copy(
            accountNpubs = cfg.accountNpubs.filter { it != npub },
            accountBunkerConfigs = cfg.accountBunkerConfigs - npub,
            accountSigningModes = cfg.accountSigningModes - npub,
            publishRelayListPerAccount = cfg.publishRelayListPerAccount - npub,
            activeAccountNpub = if (cfg.activeAccountNpub == npub) null else cfg.activeAccountNpub,
        )
    }

    fun setSigningMode(npub: String, mode: String) =
        update { it.copy(accountSigningModes = it.accountSigningModes + (npub to mode)) }

    fun setBunkerConfig(npub: String, bunker: AccountBunkerConfig) =
        update { it.copy(accountBunkerConfigs = it.accountBunkerConfigs + (npub to bunker)) }

    fun removeBunkerConfig(npub: String) =
        update { it.copy(accountBunkerConfigs = it.accountBunkerConfigs - npub) }

    fun setPublishRelayList(npub: String, enabled: Boolean) =
        update { it.copy(publishRelayListPerAccount = it.publishRelayListPerAccount + (npub to enabled)) }

    /** Factory reset -- delete config and all data. */
    suspend fun resetApp() = withContext(Dispatchers.IO) {
        configFile.delete()
        _config.value = HavenConfig()
        _activeAccountHexPubkey.value = ""
    }
}
