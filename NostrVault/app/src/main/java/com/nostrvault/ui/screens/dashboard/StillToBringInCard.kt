package com.nostrvault.ui.screens.dashboard

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CloudDownload
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.service.ImportJobService
import com.nostrvault.service.ImportJobs
import com.nostrvault.ui.notification.NotificationManager
import com.nostrvault.ui.notification.PillTone
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Vault › Still to bring in (Logen's first-run plan §3): the relay's import jobs past `setup`, each run only when
 * tapped (Logen's answers 1 and 2). Each row says what it is, how long, how it last ended, and Run / Run again or
 * Cancel. A partial run lists the ranges it didn't read. Re-read on every `IMPORT_JOB` line (ImportJobService).
 */
@Composable
internal fun StillToBringInCard(viewModel: StillToBringInViewModel = hiltViewModel()) {
    val jobs by viewModel.jobs.collectAsState()
    // Status changes arrive as IMPORT_JOB lines; a slow re-read keeps a running row's count moving too.
    LaunchedEffect(Unit) {
        while (true) {
            viewModel.refresh()
            delay(if (jobs?.jobs?.any { it.isRunning } == true) 3_000L else 30_000L)
        }
    }
    val rows = jobs?.stillToBringIn.orEmpty()
    if (rows.isEmpty()) return
    val anyRunning = rows.any { it.isRunning } || jobs?.job(ImportJobs.SETUP)?.isRunning == true
    val now = System.currentTimeMillis() / 1000
    DashSection(title = "Still to bring in") {
        rows.forEachIndexed { i, job ->
            if (i > 0) DashDivider()
            JobRow(job, now, anyRunning, onRun = { viewModel.run(job.name) }, onCancel = { viewModel.cancel(job.name) })
        }
    }
}

@Composable
private fun JobRow(job: ImportJobs.Job, nowS: Long, anyRunning: Boolean, onRun: () -> Unit, onCancel: () -> Unit) {
    val state = when (job.status) {
        ImportJobs.DONE -> RowState.DONE
        ImportJobs.NEVER -> RowState.INFO
        else -> RowState.TODO
    }
    DashRow(
        icon = Icons.Filled.CloudDownload,
        title = ImportJobs.title(job.name),
        detail = listOf(ImportJobs.blurb(job.name), ImportJobs.statusLine(job, nowS)).filter { it.isNotEmpty() }.joinToString("\n"),
        state = state,
    ) {
        when {
            job.isRunning -> RowButton(title = "Cancel", onClick = onCancel)
            // One job at a time (the engine answers busy): the others wait.
            else -> RowButton(title = if (job.status == ImportJobs.NEVER) "Run" else "Run again", enabled = !anyRunning, onClick = onRun)
        }
    }
    val unread = ImportJobs.unreadLines(job)
    if (job.status == ImportJobs.PARTIAL && unread.isNotEmpty()) {
        Column(
            verticalArrangement = Arrangement.spacedBy(2.dp),
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = 52.dp, end = 14.dp, bottom = 10.dp)
                .semantics { stateDescription = "Not read: ${unread.size}" },
        ) {
            Text("Not read:", color = PrimaryText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
            unread.take(MAX_UNREAD_SHOWN).forEach { Text(it, color = SecondaryText, fontSize = 12.sp) }
            if (unread.size > MAX_UNREAD_SHOWN) Text("and ${unread.size - MAX_UNREAD_SHOWN} more", color = SecondaryText, fontSize = 12.sp)
        }
    }
}

private const val MAX_UNREAD_SHOWN = 6

@HiltViewModel
class StillToBringInViewModel @Inject constructor(
    private val service: ImportJobService,
    private val notificationManager: NotificationManager,
) : ViewModel() {
    val jobs = service.jobs

    fun refresh() = service.refresh()

    fun run(name: String) {
        viewModelScope.launch {
            ImportJobs.runRefusal(service.run(name))?.let { notificationManager.showToast(it, PillTone.WARNING) }
        }
    }

    fun cancel(name: String) {
        viewModelScope.launch { service.cancel(name) }
    }
}
