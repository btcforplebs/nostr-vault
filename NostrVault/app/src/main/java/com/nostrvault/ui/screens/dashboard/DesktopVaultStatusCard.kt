package com.nostrvault.ui.screens.dashboard

import android.content.Context
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.DesktopVaultPick
import com.nostrvault.data.model.VaultStatus
import com.nostrvault.data.model.VaultStatusText
import com.nostrvault.fips.DeviceRole
import com.nostrvault.fips.FipsMeshManager
import com.nostrvault.fips.MeshCopyStarter
import com.nostrvault.fips.MyDevice
import com.nostrvault.fips.MyDevicesRules
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.VaultStatusBridge
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.withContext
import javax.inject.Inject

/**
 * Vault Dashboard › Your desktop Vault: what the desktop Vault's trust ranking, distant posts and hand-off are doing,
 * read over the mesh with the copy token (never the account key), and how old that read is. Nothing when no desktop
 * is in My Devices. Twin of iOS `DesktopVaultStatusCard.swift`.
 */
@Composable
internal fun DesktopVaultStatusCard(viewModel: DesktopVaultStatusViewModel = hiltViewModel()) {
    val desktop by viewModel.desktop.collectAsState()
    val shown by viewModel.shown.collectAsState()
    val d = desktop ?: return
    // On screen: read now, then every minute.
    LaunchedEffect(d.npub) {
        viewModel.show(d.npub)
        while (true) {
            viewModel.refresh()
            delay(REFRESH_MS)
        }
    }
    val nowS by produceState(System.currentTimeMillis() / 1000) {
        while (true) {
            delay(30_000)
            value = System.currentTimeMillis() / 1000
        }
    }
    DashSection(title = "Your desktop Vault", detail = age(shown, nowS)) {
        Column(
            verticalArrangement = Arrangement.spacedBy(5.dp),
            modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp).semantics(mergeDescendants = true) {},
        ) {
            Text(d.title, color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            val status = shown.status
            if (status == null) {
                Line(if (shown.error == null) "Checking…" else reach(shown.error)?.replaceFirstChar { it.uppercase() } ?: "Checking…")
                return@Column
            }
            Text(VaultStatusText.headline(status), color = PrimaryText, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
            VaultStatusText.pausedHint(status)?.let { Line(it) }
            val a = status.account(viewModel.activeHex()) ?: return@Column
            VaultStatusText.progress(a)?.let { Line(it) }
            Line(VaultStatusText.finished(a, nowS))
            VaultStatusText.distant(a, viewModel.bar())?.let { Line(it) }
            Line(VaultStatusText.distantFetch(a, nowS))
            val named = viewModel.namedDevices()
            val selfHex = viewModel.selfHex()
            a.handoffs.forEach { h ->
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(
                        DesktopVaultPick.handoffName(h, named, selfHex) { r -> DeviceRole.entries.firstOrNull { it.serialName() == r }?.label },
                        color = PrimaryText, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                    Text(VaultStatusText.handoff(h, nowS), color = SecondaryText, fontSize = 13.sp)
                }
            }
        }
    }
}

@Composable
private fun Line(text: String) = Text(text, color = SecondaryText, fontSize = 13.sp)

/** "Updated 3 min ago", or why there is nothing newer (iOS DesktopVaultStatusCard.age). */
private fun age(shown: DesktopVaultStatusViewModel.Shown, nowS: Long): String? {
    if (shown.fetchedAt <= 0) return null
    val updated = DesktopVaultPick.updated(shown.fetchedAt, nowS)
    return reach(shown.error)?.let { "$updated, $it now" } ?: updated
}

private fun reach(error: String?): String? = when (error) {
    null -> null
    "not_paired" -> "not caught up with yet"
    "not_found" -> "update it to see this"
    else -> "out of reach"
}

/** The role's name as the engine and iOS write it ("mac", "phone", …). */
private fun DeviceRole.serialName(): String = when (this) {
    DeviceRole.MAC -> "mac"
    DeviceRole.PHONE -> "phone"
    DeviceRole.HOME_VAULT -> "homeVault"
    DeviceRole.BROWSER -> "browser"
}

private const val REFRESH_MS = 60_000L

@HiltViewModel
class DesktopVaultStatusViewModel @Inject constructor(
    @ApplicationContext context: Context,
    private val configStore: ConfigStore,
    private val mesh: FipsMeshManager,
    private val copies: MeshCopyStarter,
) : ViewModel() {
    /** The last good answer from [peer], when it came, and the last try's error. */
    data class Shown(val peer: String = "", val status: VaultStatus? = null, val fetchedAt: Long = 0, val error: String? = null)

    private val prefs = context.getSharedPreferences("desktop_vault_status", Context.MODE_PRIVATE)
    private val _shown = MutableStateFlow(load())
    val shown: StateFlow<Shown> = _shown.asStateFlow()

    private val devices = combine(configStore.config, mesh.status) { cfg, st ->
        MyDevicesRules.list(cfg.fipsPeers, cfg.homeVaultNpub, cfg.fipsMesh.devices, st.peers, cfg.ownerNpub)
    }.stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    val desktop: StateFlow<MyDevice?> = combine(devices, copies.sync) { list, sync ->
        DesktopVaultPick.desktop(list.filter { it.role == DeviceRole.MAC }, { it.npub }, sync.lastAt)
    }.stateIn(viewModelScope, SharingStarted.Eagerly, null)

    fun activeHex(): String = configStore.activeAccountHexPubkey.value

    fun bar(): Double? = configStore.config.value.discoveryBar?.takeIf { it in 0.0..100.0 }?.let { Math.round(it).toDouble() }

    fun namedDevices(): Map<String, String> =
        devices.value.mapNotNull { d -> HavenBridge.decodeNpub(d.npub)?.lowercase()?.let { it to d.title } }.toMap()

    fun selfHex(): String? = mesh.status.value.npub?.let { HavenBridge.decodeNpub(it) }

    /** Shown for [peer]: drop what was kept for another desktop. */
    fun show(peer: String) {
        if (_shown.value.peer == peer) return
        _shown.value = Shown(peer = peer)
        prefs.edit().clear().apply()
    }

    suspend fun refresh() {
        val peer = _shown.value.peer.ifEmpty { return }
        val raw = withContext(Dispatchers.IO) { copies.statusBase(peer)?.let { VaultStatusBridge.read(peer, it) } }
        if (_shown.value.peer != peer) return
        val (ok, error) = raw?.let(VaultStatus::answer) ?: (null to "unreachable")
        _shown.value = if (ok != null) {
            val now = System.currentTimeMillis() / 1000
            prefs.edit().putString(KEY_PEER, peer).putLong(KEY_AT, now).putString(KEY_JSON, ok.second).apply()
            Shown(peer, ok.first, now, null)
        } else {
            _shown.value.copy(error = error ?: "bad_answer")
        }
    }

    private fun load(): Shown {
        val peer = prefs.getString(KEY_PEER, null) ?: return Shown()
        val status = prefs.getString(KEY_JSON, null)?.let(VaultStatus::decode)
        return Shown(peer, status, if (status != null) prefs.getLong(KEY_AT, 0) else 0)
    }

    private companion object {
        const val KEY_PEER = "peer"
        const val KEY_AT = "fetched_at"
        const val KEY_JSON = "json"
    }
}
