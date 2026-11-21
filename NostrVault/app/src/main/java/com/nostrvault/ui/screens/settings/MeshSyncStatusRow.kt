package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.fips.MeshCopyStarter
import com.nostrvault.fips.MeshCopyV2
import com.nostrvault.fips.MeshSyncState
import com.nostrvault.fips.MyDevice
import com.nostrvault.fips.MyDevicesRules
import com.nostrvault.ui.screens.settings.fipsmesh.MeshDivider
import com.nostrvault.ui.screens.settings.fipsmesh.MeshSection
import com.nostrvault.ui.screens.settings.fipsmesh.StatusDot
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.StateFlow
import javax.inject.Inject

/**
 * The mesh catch-up behind Settings › Your Devices: one row per device this phone copies from, with when it last
 * synced and what it is doing, and one Sync now for all of them. Pure for the tests. Twin of Apple's
 * `MeshSyncStatusRow` (3.3.0 A4).
 */
object MeshSyncStatus {
    enum class State { SYNCING, WAITING, FAILED, UP_TO_DATE }

    data class Row(val npub: String, val name: String, val lastLine: String, val state: State, val stateLine: String)

    /** The listed devices this phone has copied from, in the list's order; the rest have no catch-up to run. */
    fun rows(devices: List<MyDevice>, sync: MeshSyncState, progress: MeshCopyV2.Line?, now: Long): List<Row> =
        devices.filter { it.npub in sync.lastAt || it.npub == sync.running }.map { d ->
            val state = state(d.npub, sync)
            Row(d.npub, d.title, lastLine(sync.lastAt[d.npub] ?: 0, now), state, stateLine(state, sync.failed[d.npub], progress))
        }

    fun state(npub: String, sync: MeshSyncState): State = when {
        sync.running == npub -> State.SYNCING
        npub in sync.queued -> State.WAITING
        npub in sync.failed -> State.FAILED
        else -> State.UP_TO_DATE
    }

    /** "Last synced 5 min ago" / "Never synced". */
    fun lastLine(lastAt: Long, now: Long): String =
        if (lastAt <= 0) "Never synced"
        else "Last synced " + MyDevicesRules.lastSeenText(lastAt, false, now).replaceFirstChar { it.lowercase() }

    fun stateLine(state: State, error: String?, progress: MeshCopyV2.Line?): String = when (state) {
        State.SYNCING -> progress?.takeIf { it.stage == "fetching" && it.bytes.second > 0 }
            ?.let { "Syncing… ${(it.bytes.first * 100 / it.bytes.second).coerceIn(0, 100)}%" } ?: "Syncing…"
        State.WAITING -> "Waiting to sync"
        State.FAILED -> if (error == "unreachable") "Couldn't reach it. Make sure it's on and Nostr Vault is open."
            else "The last sync didn't finish."
        State.UP_TO_DATE -> "Up to date"
    }

    /** Sync now: after setup, with a device to sync, and nothing already running or waiting. */
    fun syncEnabled(setupDone: Boolean, rows: List<Row>, sync: MeshSyncState): Boolean =
        setupDone && rows.isNotEmpty() && sync.running == null && sync.queued.isEmpty()

    const val HEADER = "Sync with your vaults"
    const val FOOTER = "Your devices catch up on their own every 15 minutes while Nostr Vault is open. " +
        "Sync now does it right away, with each of them in turn."
}

@HiltViewModel
class MeshSyncViewModel @Inject constructor(
    private val starter: MeshCopyStarter,
    private val configStore: ConfigStore,
) : ViewModel() {
    val sync: StateFlow<MeshSyncState> = starter.sync
    val progress: StateFlow<MeshCopyV2.Line?> = starter.progress
    val setupDone: Boolean get() = configStore.config.value.hasCompletedSetup
    fun syncNow() = starter.syncNow()
}

/** The section: hidden until this phone has copied from a device. [now] is re-read with the screen's own refresh. */
@Composable
internal fun MeshSyncStatusSection(devices: List<MyDevice>, now: Long, viewModel: MeshSyncViewModel = hiltViewModel()) {
    val sync by viewModel.sync.collectAsState()
    val progress by viewModel.progress.collectAsState()
    val rows = MeshSyncStatus.rows(devices, sync, progress, now)
    if (rows.isEmpty()) return
    MeshSection(MeshSyncStatus.HEADER, footer = MeshSyncStatus.FOOTER) {
        rows.forEachIndexed { i, r ->
            if (i > 0) MeshDivider()
            MeshSyncStatusRow(r)
        }
        MeshDivider()
        val colors = LocalNostrVaultColors.current
        Button(
            onClick = viewModel::syncNow,
            enabled = MeshSyncStatus.syncEnabled(viewModel.setupDone, rows, sync),
            shape = RoundedCornerShape(10.dp),
            colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
            modifier = Modifier.fillMaxWidth().padding(vertical = 10.dp),
        ) { Text(YourDevicesRules.SYNC_NOW) }
    }
}

/** One device: its name, when it last synced, and a dot with what its catch-up is doing. */
@Composable
internal fun MeshSyncStatusRow(row: MeshSyncStatus.Row) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp)) {
        Column(Modifier.weight(1f)) {
            Text(row.name, color = PrimaryText, fontSize = 16.sp, maxLines = 1)
            Text(row.lastLine, color = SecondaryText, fontSize = 13.sp)
            StatusDot(
                row.stateLine,
                on = true,
                warning = row.state == MeshSyncStatus.State.FAILED || row.state == MeshSyncStatus.State.WAITING,
            )
        }
    }
}
