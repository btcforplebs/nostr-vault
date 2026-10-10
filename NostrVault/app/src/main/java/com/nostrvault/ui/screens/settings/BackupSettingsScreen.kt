package com.nostrvault.ui.screens.settings

import android.content.Context
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.RelayImportService
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import javax.inject.Inject

@HiltViewModel
class BackupSettingsViewModel @Inject constructor(
    @ApplicationContext private val context: Context,
    private val configStore: ConfigStore,
    private val relayImportService: RelayImportService,
    /** Exports here count as the Vault Dashboard's backups too (iOS VaultHistory). */
    private val vaultHistory: com.nostrvault.data.local.VaultHistoryStore,
) : ViewModel() {
    private val _busy = MutableStateFlow(false)
    val busy = _busy.asStateFlow()

    private val _status = MutableStateFlow("")
    val status = _status.asStateFlow()

    private val blossomDir: String
        get() = File(File(context.filesDir, "relay_data"), "blossom").absolutePath

    // Notes export/import touch the databases, which the running relay holds open
    // in-process. They must run with the relay stopped (withRelayStopped), then it
    // restarts. Media export/import only zip the blossom directory — no relay stop.

    fun exportNotes(dest: Uri) = run(
        "Exporting notes…", "Notes exported", dest = dest, stopRelay = true,
        onSuccess = { vaultHistory.record(com.nostrvault.data.local.VaultHistory.Entry.NOTES_BACKUP) },
    ) { tmp ->
        HavenBridge.backupDatabase(tmp.absolutePath)
    }

    fun importNotes(src: Uri) = run("Restoring notes…", "Notes restored", src = src, stopRelay = true) { tmp ->
        HavenBridge.restoreDatabase(tmp.absolutePath)
    }

    fun exportMedia(
        dest: Uri,
    ) = run("Exporting media…", "Media exported", dest = dest, onSuccess = { vaultHistory.record(com.nostrvault.data.local.VaultHistory.Entry.MEDIA_BACKUP) }) { tmp ->
        HavenBridge.zipDirectory(blossomDir, tmp.absolutePath)
    }

    fun importMedia(src: Uri) = run("Restoring media…", "Media restored", src = src) { tmp ->
        HavenBridge.unzipDirectory(tmp.absolutePath, blossomDir)
    }

    /**
     * Bridges SAF (content Uris) to the Go bridge (filesystem paths) via a temp file.
     * For export: [op] writes the temp file, then it's copied to [dest].
     * For import: [src] is copied to the temp file, then [op] consumes it.
     * When [stopRelay] is true, [op] runs with the relay stopped (DB exclusivity).
     */
    private fun run(
        working: String,
        done: String,
        dest: Uri? = null,
        src: Uri? = null,
        stopRelay: Boolean = false,
        onSuccess: () -> Unit = {},
        op: (File) -> Int,
    ) {
        if (_busy.value) return
        viewModelScope.launch {
            _busy.value = true
            _status.value = working
            try {
                val tmp = withContext(Dispatchers.IO) {
                    File.createTempFile("backup", ".zip", context.cacheDir)
                }
                try {
                    if (src != null) {
                        withContext(Dispatchers.IO) {
                            context.contentResolver.openInputStream(src)?.use { input ->
                                tmp.outputStream().use { input.copyTo(it) }
                            } ?: error("Could not open backup file")
                        }
                    }
                    // DB ops need the relay stopped for exclusive access; media ops don't.
                    val code = if (stopRelay) {
                        relayImportService.withRelayStopped(onStatus = { _status.value = it }) { op(tmp) }
                    } else {
                        withContext(Dispatchers.IO) { op(tmp) }
                    }
                    if (code != 0) error("Operation failed (code $code)")
                    if (dest != null) {
                        withContext(Dispatchers.IO) {
                            context.contentResolver.openOutputStream(dest)?.use { out ->
                                tmp.inputStream().use { it.copyTo(out) }
                            } ?: error("Could not write to destination")
                        }
                    }
                } finally {
                    withContext(Dispatchers.IO) { tmp.delete() }
                }
                onSuccess()
                _status.value = done
            } catch (e: Exception) {
                _status.value = "Error: ${e.message}"
            } finally {
                _busy.value = false
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BackupSettingsScreen(
    onBack: () -> Unit,
    viewModel: BackupSettingsViewModel = hiltViewModel(),
) {
    val busy by viewModel.busy.collectAsState()
    val status by viewModel.status.collectAsState()

    val createNotes = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("application/zip"),
    ) { uri -> uri?.let(viewModel::exportNotes) }
    val openNotes = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri -> uri?.let(viewModel::importNotes) }
    val createMedia = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("application/zip"),
    ) { uri -> uri?.let(viewModel::exportMedia) }
    val openMedia = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri -> uri?.let(viewModel::importMedia) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Backup") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(NostrVaultIcons.Back, contentDescription = "Back")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = WindowBackground,
                    titleContentColor = PrimaryText,
                    navigationIconContentColor = PrimaryText,
                ),
            )
        },
        containerColor = WindowBackground,
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
        ) {
            SectionLabel("Notes (JSONL)", SettingsHelp.RELAY_BACKUP)
            BackupRow(
                title = "Export Notes",
                subtitle = "Save all notes and metadata as a JSONL backup (.zip)",
                buttonText = "Export",
                enabled = !busy,
            ) { createNotes.launch("nostrvault-notes-backup.zip") }
            BackupRow(
                title = "Import Notes",
                subtitle = "Restore notes from a Nostr Vault JSONL backup (.zip)",
                buttonText = "Import",
                enabled = !busy,
            ) { openNotes.launch(arrayOf("application/zip", "application/octet-stream")) }

            Spacer(Modifier.height(20.dp))

            SectionLabel("Media (Blossom)")
            BackupRow(
                title = "Export Media",
                subtitle = "Save all Blossom media files as a backup (.zip)",
                buttonText = "Export",
                enabled = !busy,
            ) { createMedia.launch("nostrvault-media-backup.zip") }
            BackupRow(
                title = "Import Media",
                subtitle = "Restore media from a Blossom backup (.zip)",
                buttonText = "Import",
                enabled = !busy,
            ) { openMedia.launch(arrayOf("application/zip", "application/octet-stream")) }

            if (busy || status.isNotEmpty()) {
                Spacer(Modifier.height(20.dp))
                if (busy) LinearProgressIndicator(
                    modifier = Modifier.fillMaxWidth(),
                    color = LocalNostrVaultColors.current.primary,
                )
                if (status.isNotEmpty()) {
                    Spacer(Modifier.height(8.dp))
                    val isError = status.startsWith("Error")
                    Text(status, color = if (isError) ErrorRed else SecondaryText, fontSize = 13.sp)
                }
            }

            Spacer(Modifier.height(32.dp))
        }
    }
}

@Composable
private fun BackupRow(
    title: String,
    subtitle: String,
    buttonText: String,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    Row(
        verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(title, color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
            Text(subtitle, color = SecondaryText, fontSize = 12.sp)
        }
        Spacer(Modifier.width(12.dp))
        Button(
            onClick = onClick,
            enabled = enabled,
            colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
        ) { Text(buttonText) }
    }
}

