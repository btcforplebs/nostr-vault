package com.nostrvault.ui.screens

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.*
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.launch
import java.io.File

// ══════════════════════════════════════════════════════════════════
// Step 5: Import Notes
// ══════════════════════════════════════════════════════════════════

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ImportNotesStep(viewModel: SetupWizardViewModel) {
    val isImporting by viewModel.isImporting.collectAsState()
    val importStatus by viewModel.importStatus.collectAsState()
    val importCompleted by viewModel.importCompleted.collectAsState()
    val importStartDate by viewModel.importStartDate.collectAsState()
    val context = LocalContext.current

    // Importing can run 20+ minutes; don't let the screen dim or lock while it's up.
    val view = LocalView.current
    DisposableEffect(view) {
        view.keepScreenOn = true
        onDispose { view.keepScreenOn = false }
    }

    var selectedTab by remember { mutableIntStateOf(0) }
    val tabs = listOf("Network", "Backup")
    var showDatePicker by remember { mutableStateOf(false) }

    // File picker for backup restore
    val backupPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument()
    ) { uri ->
        uri?.let {
            // Copy to temp file for JNI access
            val tempFile = File(context.cacheDir, "restore_backup.zip")
            context.contentResolver.openInputStream(it)?.use { input ->
                tempFile.outputStream().use { output -> input.copyTo(output) }
            }
            viewModel.restoreFromBackup(tempFile.absolutePath)
        }
    }

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            text = "Import Notes",
            color = PrimaryText,
            fontSize = 20.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = "Bring your existing notes into your vault.",
            color = SecondaryText,
            fontSize = 14.sp,
            textAlign = TextAlign.Center,
        )

        Spacer(Modifier.height(20.dp))

        // Tab selector
        WizardTabRow(tabs = tabs, selectedTab = selectedTab, onTabSelected = { selectedTab = it })

        Spacer(Modifier.height(16.dp))

        AnimatedContent(
            targetState = selectedTab,
            label = "import_tab",
        ) { tab ->
            when (tab) {
                0 -> {
                    // Network import
                    WizardCard {
                        Text(
                            text = "Import from Network",
                            color = PrimaryText,
                            fontSize = 16.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Spacer(Modifier.height(8.dp))
                        Text(
                            text = "Fetch your notes from public relays and store them locally.",
                            color = SecondaryText,
                            fontSize = 14.sp,
                            lineHeight = 20.sp,
                        )

                        if (importStatus.isNotEmpty()) {
                            Spacer(Modifier.height(12.dp))
                            Text(
                                text = importStatus,
                                color = if (importCompleted) SuccessGreen else SecondaryText,
                                fontSize = 13.sp,
                            )
                        }

                        if (isImporting) {
                            Spacer(Modifier.height(12.dp))
                            LinearProgressIndicator(
                                color = WizardAccent,
                                trackColor = WizardBgElevated,
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }

                        if (!isImporting && !importCompleted) {
                            Spacer(Modifier.height(12.dp))
                            HorizontalDivider(color = WizardBorderSubtle)
                            Spacer(Modifier.height(12.dp))

                            // Date picker row
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(8.dp))
                                    .clickable { showDatePicker = true }
                                    .padding(vertical = 8.dp),
                            ) {
                                Text(
                                    text = "Import from",
                                    color = SecondaryText,
                                    fontSize = 14.sp,
                                )
                                Spacer(Modifier.weight(1f))
                                Text(
                                    text = importStartDate,
                                    color = WizardAccent,
                                    fontSize = 14.sp,
                                    fontWeight = FontWeight.Medium,
                                )
                            }
                        }

                        Spacer(Modifier.height(16.dp))

                        if (!isImporting && !importCompleted) {
                            WizardPrimaryButton(
                                text = "Import Notes",
                                onClick = viewModel::startNetworkImport,
                            )
                        } else if (isImporting) {
                            WizardSecondaryButton(
                                text = "Cancel",
                                onClick = viewModel::cancelImport,
                            )
                        }
                    }
                }
                1 -> {
                    // Backup restore
                    WizardCard {
                        Text(
                            text = "Restore from Backup",
                            color = PrimaryText,
                            fontSize = 16.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Spacer(Modifier.height(8.dp))
                        Text(
                            text = "Restore from a previous Nostr Vault backup file (.zip).",
                            color = SecondaryText,
                            fontSize = 14.sp,
                            lineHeight = 20.sp,
                        )

                        if (importStatus.isNotEmpty()) {
                            Spacer(Modifier.height(12.dp))
                            Text(
                                text = importStatus,
                                color = if (importCompleted) SuccessGreen else SecondaryText,
                                fontSize = 13.sp,
                            )
                        }

                        if (isImporting) {
                            Spacer(Modifier.height(12.dp))
                            LinearProgressIndicator(
                                color = WizardAccent,
                                trackColor = WizardBgElevated,
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }

                        Spacer(Modifier.height(16.dp))

                        if (!isImporting && !importCompleted) {
                            WizardPrimaryButton(
                                text = "Choose Backup File",
                                onClick = {
                                    backupPicker.launch(arrayOf(
                                        "application/zip",
                                        "application/x-zip-compressed",
                                    ))
                                },
                            )
                        }
                    }
                }
            }
        }

        Spacer(Modifier.height(24.dp))

        if (importCompleted) {
            WizardPrimaryButton(text = "Continue", onClick = viewModel::advanceFromImport)
        } else if (!isImporting) {
            WizardSecondaryButton(text = "Skip", onClick = viewModel::skipImport)
        }
    }

    // Date picker dialog
    if (showDatePicker) {
        val datePickerState = rememberDatePickerState(
            initialSelectedDateMillis = try {
                java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US).let { fmt ->
                    fmt.timeZone = java.util.TimeZone.getTimeZone("UTC")
                    fmt.parse(importStartDate)?.time ?: 0L
                }
            } catch (_: Exception) { 0L }
        )
        DatePickerDialog(
            onDismissRequest = { showDatePicker = false },
            confirmButton = {
                TextButton(onClick = {
                    datePickerState.selectedDateMillis?.let { millis ->
                        val fmt = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US)
                        fmt.timeZone = java.util.TimeZone.getTimeZone("UTC")
                        viewModel.setImportStartDate(fmt.format(java.util.Date(millis)))
                    }
                    showDatePicker = false
                }) { Text("OK") }
            },
            dismissButton = {
                TextButton(onClick = { showDatePicker = false }) { Text("Cancel") }
            },
        ) {
            DatePicker(state = datePickerState)
        }
    }
}
