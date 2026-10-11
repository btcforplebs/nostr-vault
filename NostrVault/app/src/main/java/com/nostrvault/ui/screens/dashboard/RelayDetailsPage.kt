package com.nostrvault.ui.screens.dashboard

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import com.nostrvault.data.model.*
import com.nostrvault.relay.RelayForegroundService
import com.nostrvault.ui.navigation.Screen
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.*

/** Advanced › Relay details: the relay dashboard the Vault Dashboard replaced (iOS DashboardView). */
@Composable
internal fun RelayDetailsPage(
    viewModel: DashboardViewModel,
    logStore: com.nostrvault.relay.LogStore,
    onNavigate: (Screen) -> Unit,
    onDismiss: () -> Unit,
    onBack: () -> Unit,
) {
    val totalEvents by viewModel.totalEvents.collectAsState()
    val storageUsed by viewModel.storageUsed.collectAsState()
    val noteCount by viewModel.noteCount.collectAsState()
    val dmCount by viewModel.dmCount.collectAsState()
    val mediaCount by viewModel.mediaCount.collectAsState()
    val mediaSize by viewModel.mediaSize.collectAsState()
    val statsLoading by viewModel.statsLoading.collectAsState()
    val currentRelayStatus by RelayForegroundService.relayStatus.collectAsState()
    val currentIsLocked by RelayForegroundService.isLocked.collectAsState()
    val currentIsPortConflict by RelayForegroundService.isPortConflict.collectAsState()
    val currentLogs by logStore.logs.collectAsState()
    val currentConfig by viewModel.configStore.config.collectAsState()
    val context = LocalContext.current

    LaunchedEffect(Unit) { viewModel.loadStats() }

    DashboardSheetContent(
        title = "Relay details",
        onBack = onBack,
        totalEvents = totalEvents,
        storageUsed = storageUsed,
        noteCount = noteCount,
        dmCount = dmCount,
        mediaCount = mediaCount,
        mediaSize = mediaSize,
        isLoading = statsLoading,
        relayStatus = currentRelayStatus,
        relayAddress = currentConfig.nostrURL,
        isExternalRelay = currentConfig.useExternalRelay,
        isLocked = currentIsLocked,
        isPortConflict = currentIsPortConflict,
        onRefresh = viewModel::loadStats,
        blossomSection = null,
        onStartRelay = { RelayForegroundService.start(context) },
        onStopRelay = { RelayForegroundService.stop(context) },
        onRestartRelay = {
            RelayForegroundService.stop(context)
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                RelayForegroundService.start(context)
            }, 1500)
        },
        onForceRestart = { RelayForegroundService.forceRestart(context) },
        onClearLocks = { RelayForegroundService.clearLocksPublic(context) },
        logs = currentLogs,
        onViewAllLogs = {
            onDismiss()
            onNavigate(Screen.RelayActivity)
        },
        statsService = viewModel.statsService,
        ownerPubkey = viewModel.nostrService.ownerHexPubkey,
        cacheDir = currentConfig.appSupportDir?.let { "$it/media_cache" },
        cacheTTLDays = currentConfig.cacheTTLDays,
        isImporting = viewModel.isImporting.collectAsState().value,
        importProgress = viewModel.importProgress.collectAsState().value,
        importStatusMessage = viewModel.importStatusMessage.collectAsState().value,
        importCompleted = viewModel.importCompleted.collectAsState().value,
        isExportingJsonl = viewModel.isExportingJsonl.collectAsState().value,
        isExportingMedia = viewModel.isExportingMedia.collectAsState().value,
        isImportingBlossom = viewModel.blossomMirrorRun.collectAsState().value.running,
        onImportNotes = { viewModel.importNotes(context) },
        onImportBlossom = viewModel::importBlossom,
        onExportJsonl = { viewModel.exportJsonl(context) },
        onExportMedia = { viewModel.exportMedia(context) },
        onDismissImport = viewModel::dismissImport,
    )
}
