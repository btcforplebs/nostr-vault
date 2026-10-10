package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenConfig
import com.nostrvault.service.RelayImportService
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.StateFlow
import javax.inject.Inject

@HiltViewModel
class ImportSettingsViewModel @Inject constructor(
    private val configStore: ConfigStore,
    private val relayImportService: RelayImportService,
) : ViewModel() {
    val config: StateFlow<HavenConfig> = configStore.config
    val isImporting = relayImportService.isImporting
    val importProgress = relayImportService.importProgress
    val statusMessage = relayImportService.importStatusMessage

    fun setStartDate(date: String) = configStore.update { it.copy(importStartDate = date) }

    fun startImport() = relayImportService.importNotes()
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ImportSettingsScreen(
    onBack: () -> Unit,
    viewModel: ImportSettingsViewModel = hiltViewModel(),
) {
    val config by viewModel.config.collectAsState()
    val isImporting by viewModel.isImporting.collectAsState()
    val progress by viewModel.importProgress.collectAsState()
    val status by viewModel.statusMessage.collectAsState()
    val focusManager = androidx.compose.ui.platform.LocalFocusManager.current
    val colors = LocalNostrVaultColors.current

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Import") },
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
            SectionLabel("Import Configuration", SettingsHelp.RELAY_IMPORT)
            // Commits on Done / focus loss / leaving: the start date is part of
            // the relay's start config, so saving it restarts the relay.
            CommitOnEndTextField(
                value = config.importStartDate,
                onCommit = viewModel::setStartDate,
                label = { Text("Start Date (YYYY-MM-DD)") },
                modifier = Modifier.fillMaxWidth(),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedTextColor = PrimaryText,
                    unfocusedTextColor = PrimaryText,
                    cursorColor = colors.primary,
                    focusedBorderColor = colors.primary,
                ),
            )
            Text(
                "Notes will be fetched starting from this date.",
                color = SecondaryText, fontSize = 12.sp,
                modifier = Modifier.padding(top = 6.dp),
            )

            Spacer(Modifier.height(20.dp))

            Text(
                "Import pulls from the relays with Import on, in Settings > Relays.",
                color = SecondaryText, fontSize = 12.sp,
                modifier = Modifier.padding(bottom = 6.dp),
            )
            Text(
                "The import fetches your own notes and notes where you are tagged. " +
                    "Make sure your npub is set correctly.",
                color = SecondaryText, fontSize = 12.sp,
                modifier = Modifier.padding(top = 6.dp),
            )

            Spacer(Modifier.height(24.dp))

            if (isImporting) {
                LinearProgressIndicator(
                    progress = { progress },
                    modifier = Modifier.fillMaxWidth(),
                    color = colors.primary,
                )
                Spacer(Modifier.height(8.dp))
                Text(status, color = SecondaryText, fontSize = 13.sp)
            } else {
                Button(
                    onClick = {
                        // Commits a start date still being typed before the
                        // import reads the config.
                        focusManager.clearFocus()
                        viewModel.startImport()
                    },
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
                ) { Text("Start Import") }
                if (status.isNotEmpty()) {
                    Spacer(Modifier.height(8.dp))
                    Text(status, color = SecondaryText, fontSize = 13.sp)
                }
            }

            Spacer(Modifier.height(32.dp))
        }
    }
}

