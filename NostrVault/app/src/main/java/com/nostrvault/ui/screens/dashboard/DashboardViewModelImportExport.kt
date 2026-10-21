package com.nostrvault.ui.screens.dashboard

import android.content.Intent
import android.util.Log
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.model.*
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import java.io.File
import com.nostrvault.ui.screens.dashboard.DashboardViewModel.Companion.TAG

    fun DashboardViewModel.importBlossom() { blossomService.runMirror() }

    private fun DashboardViewModel.setExportStatus(message: String, isError: Boolean = false, clearLater: Boolean = false) {
        exportStatusClear?.cancel()
        _exportStatus.value = message
        _exportStatusIsError.value = isError
        if (clearLater) {
            exportStatusClear = viewModelScope.launch {
                delay(3_000)
                _exportStatus.value = ""
                _exportStatusIsError.value = false
            }
        }
    }

    fun DashboardViewModel.importNotes() { relayImportService.importNotes() }

    fun DashboardViewModel.exportJsonl(context: android.content.Context) {
        if (_isExportingJsonl.value || _isExportingMedia.value) return
        _isExportingJsonl.value = true
        setExportStatus("Preparing notes backup…")

        viewModelScope.launch {
            try {
                val outputDir = java.io.File(context.cacheDir, "exports")
                outputDir.mkdirs()
                val outputFile = java.io.File(outputDir, "haven_backup_${System.currentTimeMillis()}.zip")

                // The Go backup opens the databases itself, so the relay has to
                // be down. iOS runBackupExport.
                val result = relayImportService.withRelayStopped(
                    onStatus = { setExportStatus(it) },
                ) {
                    com.nostrvault.relay.HavenBridge.backupDatabase(outputFile.absolutePath)
                }

                if (result == 0 && outputFile.exists()) {
                    vaultHistory.record(com.nostrvault.data.local.VaultHistory.Entry.NOTES_BACKUP)
                    val uri = androidx.core.content.FileProvider.getUriForFile(
                        context,
                        "${context.packageName}.fileprovider",
                        outputFile,
                    )
                    val intent = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
                        type = "application/zip"
                        putExtra(android.content.Intent.EXTRA_STREAM, uri)
                        addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    context.startActivity(android.content.Intent.createChooser(intent, "Export Database"))
                    setExportStatus("Ready to share", clearLater = true)
                } else {
                    setExportStatus("Notes backup failed", isError = true, clearLater = true)
                }
            } catch (e: Exception) {
                Log.e(TAG, "JSONL export failed: ${e.message}")
                setExportStatus("Notes backup failed", isError = true, clearLater = true)
            } finally {
                _isExportingJsonl.value = false
            }
        }
    }

    fun DashboardViewModel.exportMedia(context: android.content.Context) {
        if (_isExportingMedia.value || _isExportingJsonl.value) return
        _isExportingMedia.value = true
        setExportStatus("Preparing media backup…")

        viewModelScope.launch {
            try {
                val config = configStore.config.value
                val blossomDir = config.relayDataDir?.let { "$it/${config.blossomPath}" }
                if (blossomDir == null) {
                    _isExportingMedia.value = false
                    setExportStatus("Media backup failed", isError = true, clearLater = true)
                    return@launch
                }

                val outputDir = java.io.File(context.cacheDir, "exports")
                outputDir.mkdirs()
                val outputFile = java.io.File(outputDir, "haven_media_${System.currentTimeMillis()}.zip")

                // iOS file naming, so the backup restores on either platform.
                withContext(Dispatchers.IO) {
                    com.nostrvault.relay.BlossomArchive.export(java.io.File(blossomDir), outputFile)
                }

                if (outputFile.exists()) {
                    vaultHistory.record(com.nostrvault.data.local.VaultHistory.Entry.MEDIA_BACKUP)
                    val uri = androidx.core.content.FileProvider.getUriForFile(
                        context,
                        "${context.packageName}.fileprovider",
                        outputFile,
                    )
                    val intent = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
                        type = "application/zip"
                        putExtra(android.content.Intent.EXTRA_STREAM, uri)
                        addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    context.startActivity(android.content.Intent.createChooser(intent, "Export Media"))
                    setExportStatus("Ready to share", clearLater = true)
                } else {
                    setExportStatus("Media backup failed", isError = true, clearLater = true)
                }
            } catch (e: Exception) {
                Log.e(TAG, "Media export failed: ${e.message}")
                setExportStatus("Media backup failed", isError = true, clearLater = true)
            } finally {
                _isExportingMedia.value = false
            }
        }
    }

    fun DashboardViewModel.dismissImport() { relayImportService.dismissImportProgress() }

    // ── Local relay notes ────────────────────────────────────────

    // ── Local relay notes (persistent connections) ──────────────
