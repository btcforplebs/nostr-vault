package com.nostrvault.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.DesktopMac
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.DesktopVaultPick
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.TrustMapOuter
import com.nostrvault.data.model.VaultStatusText
import com.nostrvault.fips.DeviceRole
import com.nostrvault.fips.FipsMeshManager
import com.nostrvault.fips.MeshCopyStarter
import com.nostrvault.fips.MeshSyncState
import com.nostrvault.fips.MyDevicesRules
import com.nostrvault.service.DiscoveryReachStore
import com.nostrvault.ui.screens.dashboard.DashDivider
import com.nostrvault.ui.screens.dashboard.DashRow
import com.nostrvault.ui.screens.dashboard.DashSection
import com.nostrvault.ui.screens.dashboard.RowButton
import com.nostrvault.ui.screens.dashboard.RowState
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import javax.inject.Inject

/** My Web › Desktop Vault's words, apart so they can be tested (iOS `MyWebDesktopVaultSection`). */
internal object MyWebDesktopVaultWords {
    const val TITLE = "Desktop Vault"
    const val PULL_HINT = "Asks your desktop Vault for its ranking now"

    /** [foundBy]: "Found by <name>" when more than one desktop is paired ([DesktopVaultPick.foundBy]). */
    fun title(source: TrustMapOuter.Source, foundBy: String? = null): String =
        if (source == TrustMapOuter.Source.RANKED) foundBy ?: TrustMapOuter.FOUND_LABEL else TrustMapOuter.WAITING_LABEL

    /** Pull names the desktop when there is more than one. */
    fun pullHint(foundBy: String?): String =
        foundBy?.removePrefix("Found by ")?.let { "Asks $it for its ranking now" } ?: PULL_HINT

    /** [lastAt] is the desktop's last catch-up (Unix s), null before one. */
    fun detail(pulling: Boolean, failed: Boolean, lastAt: Long?, nowS: Long): String = when {
        pulling -> "Pulling the ranking over the mesh…"
        failed -> "Couldn't reach it over the mesh. Try again"
        lastAt != null && lastAt > 0 -> "Read over the mesh ${VaultStatusText.ago(lastAt, nowS)}"
        else -> "Read over the mesh"
    }
}

/** The desktop Vault this device copies from, and its catch-up (twin of iOS `DesktopVaultPick` + `MeshCopyV2Service`). */
@HiltViewModel
class MyWebDesktopVaultViewModel @Inject constructor(
    configStore: ConfigStore,
    mesh: FipsMeshManager,
    private val copies: MeshCopyStarter,
    private val reach: DiscoveryReachStore,
) : ViewModel() {
    /** The picked desktop's npub, and "Found by <name>" when more than one desktop is paired (plan §6.1). */
    private val picked: StateFlow<Pair<String, String?>?> = combine(configStore.config, mesh.status, copies.sync) { cfg, st, sync ->
        val desktops = MyDevicesRules.list(cfg.fipsPeers, cfg.homeVaultNpub, cfg.fipsMesh.devices, st.peers, cfg.ownerNpub)
            .filter { it.role == DeviceRole.MAC }
        DesktopVaultPick.desktop(desktops, { it.npub }, sync.lastAt)?.let { it.npub to DesktopVaultPick.foundBy(it.name, desktops.size) }
    }.stateIn(viewModelScope, SharingStarted.Eagerly, null)

    val desktop: StateFlow<String?> = picked.map { it?.first }.stateIn(viewModelScope, SharingStarted.Eagerly, null)
    val foundBy: StateFlow<String?> = picked.map { it?.second }.stateIn(viewModelScope, SharingStarted.Eagerly, null)

    val sync: StateFlow<MeshSyncState> = copies.sync

    /** The rank copy, for a ring's sheet. */
    val copy = reach.copy

    /**
     * Every paired desktop, the reachable ones first: a catch-up for one copied from, else a rank pull
     * ([MeshCopyStarter.pullAll]). Not only the shown one, which may be out of reach while another answers.
     */
    fun pull() = copies.pullAll()

    /** A pull's catch-up rewrote the rank file: read it now. */
    fun reread() = reach.refresh()
}

/**
 * My Web › Desktop Vault: what the globe's outer rings are, off the globe (Logen 11/24: the status sat bottom-left
 * over the web). With a rank, "Found by your desktop Vault" and one chip per ring, each opening that ring
 * ([OuterRingSheet]). A paired desktop Vault that has not ranked yet says so. Pull asks the desktop Vault for its
 * ranking now. With no desktop Vault, the invite ([HavenInviteCard]) until "Not now". iOS
 * `Views/TrustWeb/MyWebDesktopVaultSection.swift`.
 */
@Composable
internal fun MyWebDesktopVaultSection(
    accent: Color,
    profiles: Map<String, FeedProfile>,
    onNeedProfiles: (List<String>) -> Unit,
    viewModel: MyWebDesktopVaultViewModel = hiltViewModel(),
) {
    val context = LocalContext.current
    val outer = rememberTrustMapOuter()
    val copy by viewModel.copy.collectAsState()
    val inviteHidden by HavenInviteSetting.hidden(context).collectAsState()
    val desktop by viewModel.desktop.collectAsState()
    val foundBy by viewModel.foundBy.collectAsState()
    val sync by viewModel.sync.collectAsState()
    var open by remember { mutableStateOf<TrustMapOuter.Ring?>(null) }
    var pulled by remember { mutableStateOf(false) }
    val peer = desktop
    val pulling = peer != null && (sync.running == peer || peer in sync.queued)
    LaunchedEffect(pulling) {
        if (pulling) pulled = true else if (pulled) { pulled = false; viewModel.reread() }
    }

    when {
        outer.source == TrustMapOuter.Source.RANKED || outer.source == TrustMapOuter.Source.WAITING ->
            DashSection(title = MyWebDesktopVaultWords.TITLE) {
                // Any paired desktop: one never copied from gets a rank pull ([com.nostrvault.fips.MeshRankPull]).
                val canPull = peer != null
                val detail = MyWebDesktopVaultWords.detail(
                    pulling = pulling,
                    failed = peer != null && sync.failed[peer] != null,
                    lastAt = peer?.let { sync.lastAt[it] }, nowS = System.currentTimeMillis() / 1000,
                )
                DashRow(Icons.Filled.DesktopMac, MyWebDesktopVaultWords.title(outer.source, foundBy), detail, RowState.INFO) {
                    Row(Modifier.semantics { contentDescription = MyWebDesktopVaultWords.pullHint(foundBy) }) {
                        RowButton("Pull", isLoading = pulling, enabled = canPull) { viewModel.pull() }
                    }
                }
                if (outer.source == TrustMapOuter.Source.RANKED && outer.rings.isNotEmpty()) {
                    DashDivider()
                    Row(
                        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 14.dp, vertical = 11.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        for (ring in outer.rings) {
                            Text(
                                TrustMapOuter.chipText(ring), color = accent, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
                                modifier = Modifier
                                    .background(accent.copy(alpha = 0.12f), CircleShape)
                                    .clickable(role = Role.Button) { open = ring }
                                    .semantics { contentDescription = "${ring.hop} hops out, ${ring.count} people, found by your desktop Vault" }
                                    .padding(horizontal = 12.dp, vertical = 6.dp),
                            )
                        }
                    }
                }
            }
        outer.source == TrustMapOuter.Source.INVITE && inviteHidden == false ->
            DashSection(title = MyWebDesktopVaultWords.TITLE, framed = false) {
                HavenInviteCard(accent, onNotNow = { HavenInviteSetting.setHidden(context, true) })
            }
    }
    open?.let { ring ->
        OuterRingSheet(ring, copy, accent, profiles, onNeedProfiles, onDismiss = { open = null })
    }
}
