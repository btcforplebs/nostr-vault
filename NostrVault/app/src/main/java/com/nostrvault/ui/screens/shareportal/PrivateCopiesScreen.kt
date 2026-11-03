package com.nostrvault.ui.screens.shareportal

import android.content.Context
import android.content.Intent
import android.text.format.DateUtils
import android.text.format.Formatter
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.service.NostrEvent
import com.nostrvault.service.NostrService
import com.nostrvault.service.shareportal.PrivateCopyService
import com.nostrvault.service.shareportal.handlers.PrivateCopyRecord
import com.nostrvault.ui.theme.SecondaryText
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * The active account's private copies, read from the vault's /private
 * endpoint. With a remote signer or Amber a record is decrypted only when
 * tapped, so opening the list never asks the signer by itself. Open writes
 * the file to the app's shared cache and hands it to another app; Delete
 * empties the record and removes the sealed blob. Twin: PrivateCopiesView.swift.
 */
@Composable
internal fun PrivateCopiesScreen(onBack: () -> Unit, viewModel: PrivateCopiesViewModel = hiltViewModel()) {
    val state by viewModel.state.collectAsState()
    val context = LocalContext.current
    var confirm by remember { mutableStateOf<PrivateCopiesViewModel.Row?>(null) }
    LaunchedEffect(Unit) { viewModel.load() }
    // A decrypted copy lives only while this list is up (iOS: until Quick Look closes).
    DisposableEffect(Unit) { onDispose { viewModel.clearOpened() } }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
            TextButton(onClick = onBack) { Text("Back") }
            Text("Private copies", style = MaterialTheme.typography.titleMedium)
        }
        Text("Encrypted, in this device's vault only.", color = SecondaryText, style = MaterialTheme.typography.bodySmall)
        state.message?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        when {
            state.loading -> CircularProgressIndicator()
            state.rows.isEmpty() && state.message == null -> Text("No private copies yet.", color = SecondaryText)
        }
        LazyColumn(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            items(state.rows, key = { it.event.id }) { row ->
                CopyRow(
                    row = row,
                    context = context,
                    busy = state.busy == row.event.id,
                    onRead = { viewModel.read(row) },
                    onOpen = { viewModel.open(row) { file -> openFile(context, file, row.record!!.mime) } },
                    onDelete = { confirm = row },
                )
            }
        }
    }
    confirm?.let { row ->
        AlertDialog(
            onDismissRequest = { confirm = null },
            title = { Text("Delete this private copy?") },
            text = { Text("It is removed from your vault, and its key with it. This can't be undone.") },
            confirmButton = { TextButton(onClick = { confirm = null; viewModel.delete(row) }) { Text("Delete") } },
            dismissButton = { TextButton(onClick = { confirm = null }) { Text("Keep") } },
        )
    }
}

@Composable
private fun CopyRow(
    row: PrivateCopiesViewModel.Row,
    context: Context,
    busy: Boolean,
    onRead: () -> Unit,
    onOpen: () -> Unit,
    onDelete: () -> Unit,
) {
    val r = row.record
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        if (r == null) {
            Text("Locked private copy", style = MaterialTheme.typography.bodyLarge)
            Text(DateUtils.getRelativeTimeSpanString(row.event.createdAt * 1000).toString(), color = SecondaryText)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = onRead, enabled = !busy) { Text(if (row.failed) "Try again" else "Unlock") }
                TextButton(onClick = onDelete, enabled = !busy) { Text("Delete") }
            }
            if (row.failed) Text("Couldn't read it with this account's key.", color = SecondaryText)
        } else {
            Text(r.title ?: r.name, maxLines = 2, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyLarge)
            Text(
                listOf(
                    r.name.takeIf { r.title != null },
                    Formatter.formatShortFileSize(context, r.size.toLong()),
                    DateUtils.getRelativeTimeSpanString(r.savedAt * 1000).toString(),
                ).filterNotNull().joinToString(" · "),
                color = SecondaryText,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = onOpen, enabled = !busy) { Text(if (busy) "Opening…" else "Open") }
                TextButton(onClick = onDelete, enabled = !busy) { Text("Delete") }
            }
        }
    }
}

/** Hands [file] to whatever app opens [mime], through the app's FileProvider. */
private fun openFile(context: Context, file: java.io.File, mime: String) {
    val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
    val view = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    val chooser = Intent.createChooser(view, "Open with").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    runCatching { context.startActivity(chooser) }
}

@HiltViewModel
class PrivateCopiesViewModel @Inject constructor(
    private val service: PrivateCopyService,
    private val nostrService: NostrService,
) : ViewModel() {
    data class Row(val event: NostrEvent, val record: PrivateCopyRecord.Record?, val failed: Boolean = false)

    data class State(
        val loading: Boolean = false,
        val rows: List<Row> = emptyList(),
        val message: String? = null,
        /** The row whose open/read/delete is running. */
        val busy: String? = null,
    )

    private val _state = MutableStateFlow(State())
    val state = _state.asStateFlow()

    fun load() {
        _state.value = _state.value.copy(loading = true, message = null)
        viewModelScope.launch {
            val events = service.list()
            if (events == null) {
                _state.value = State(message = "Couldn't reach your vault on this device.")
                return@launch
            }
            // A remote signer or Amber is asked only on a tap (silent Amber is fine).
            val rows = events.map { e -> Row(e, service.read(e, silentOnly = true)) }
            _state.value = State(rows = rows)
        }
    }

    fun read(row: Row) = running(row) {
        val record = service.read(row.event, silentOnly = false)
        replace(row.copy(record = record, failed = record == null))
    }

    fun open(row: Row, show: (java.io.File) -> Unit) = running(row) {
        val record = row.record ?: return@running
        val file = service.open(record)
        if (file == null) _state.value = _state.value.copy(message = "Couldn't open it: the file isn't in this device's vault.")
        else show(file)
    }

    fun clearOpened() { service.clearOpened() }

    fun delete(row: Row) = running(row) {
        // The record names the blob: unlock it first (asks the signer), or nothing is deleted.
        val record = row.record ?: service.read(row.event, silentOnly = false)
        if (record == null) {
            replace(row.copy(failed = true))
            _state.value = _state.value.copy(message = "Couldn't unlock it, so nothing was deleted. Unlock it, then delete.")
            return@running
        }
        val problem = service.delete(row.event, record, nostrService.lockPostingAccount())
        if (problem != null) _state.value = _state.value.copy(message = problem)
        else _state.value = _state.value.copy(rows = _state.value.rows.filterNot { it.event.id == row.event.id })
    }

    private fun replace(row: Row) {
        _state.value = _state.value.copy(rows = _state.value.rows.map { if (it.event.id == row.event.id) row else it })
    }

    private fun running(row: Row, work: suspend () -> Unit) {
        if (_state.value.busy != null) return
        _state.value = _state.value.copy(busy = row.event.id, message = null)
        viewModelScope.launch {
            try { work() } finally { _state.value = _state.value.copy(busy = null) }
        }
    }
}
