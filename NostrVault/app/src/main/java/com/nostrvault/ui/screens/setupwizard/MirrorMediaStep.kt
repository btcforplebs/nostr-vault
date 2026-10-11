package com.nostrvault.ui.screens

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.*
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.launch
import java.io.File
import java.net.URL

// ══════════════════════════════════════════════════════════════════
// Step 6: Mirror Media (Blossom)
// ══════════════════════════════════════════════════════════════════

@Composable
internal fun MirrorMediaStep(viewModel: SetupWizardViewModel) {
    val blossomURL by viewModel.blossomURL.collectAsState()
    val isMirroring by viewModel.isMirroring.collectAsState()
    val mirrorProgress by viewModel.mirrorProgress.collectAsState()
    val mirrorStatus by viewModel.mirrorStatus.collectAsState()
    val mirrorCompleted by viewModel.mirrorCompleted.collectAsState()
    val context = LocalContext.current

    var selectedTab by remember { mutableIntStateOf(0) }
    val tabs = listOf("Server Sync", "Backup")

    // File picker for media archive
    val mediaPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument()
    ) { uri ->
        uri?.let {
            val tempFile = File(context.cacheDir, "media_import.zip")
            context.contentResolver.openInputStream(it)?.use { input ->
                tempFile.outputStream().use { output -> input.copyTo(output) }
            }
            viewModel.importMediaArchive(tempFile.absolutePath)
        }
    }

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            text = "Mirror Media",
            color = PrimaryText,
            fontSize = 20.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = "Sync your media from an external Blossom server to your device.",
            color = SecondaryText,
            fontSize = 14.sp,
            textAlign = TextAlign.Center,
        )

        Spacer(Modifier.height(20.dp))

        WizardTabRow(tabs = tabs, selectedTab = selectedTab, onTabSelected = { selectedTab = it })

        Spacer(Modifier.height(16.dp))

        AnimatedContent(
            targetState = selectedTab,
            label = "media_tab",
        ) { tab ->
            when (tab) {
                0 -> {
                    // Server sync
                    WizardCard {
                        Text(
                            text = "Sync from Blossom Server",
                            color = PrimaryText,
                            fontSize = 16.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Spacer(Modifier.height(12.dp))
                        OutlinedTextField(
                            value = blossomURL,
                            onValueChange = viewModel::setBlossomURL,
                            label = { Text("Blossom server URL") },
                            singleLine = true,
                            colors = wizardTextFieldColors(),
                            modifier = Modifier.fillMaxWidth(),
                        )

                        if (mirrorStatus.isNotEmpty()) {
                            Spacer(Modifier.height(12.dp))
                            Text(
                                text = mirrorStatus,
                                color = if (mirrorCompleted) SuccessGreen else SecondaryText,
                                fontSize = 13.sp,
                            )
                        }

                        if (isMirroring) {
                            Spacer(Modifier.height(12.dp))
                            if (mirrorProgress >= 0f) {
                                LinearProgressIndicator(
                                    progress = { mirrorProgress },
                                    color = WizardAccent,
                                    trackColor = WizardBgElevated,
                                    modifier = Modifier.fillMaxWidth(),
                                )
                            } else {
                                LinearProgressIndicator(
                                    color = WizardAccent,
                                    trackColor = WizardBgElevated,
                                    modifier = Modifier.fillMaxWidth(),
                                )
                            }
                        }

                        Spacer(Modifier.height(16.dp))

                        if (!isMirroring && !mirrorCompleted) {
                            WizardPrimaryButton(
                                text = "Start Sync",
                                enabled = blossomURL.isNotBlank(),
                                onClick = viewModel::startMediaMirror,
                            )
                        }
                    }
                }
                1 -> {
                    // Backup import
                    WizardCard {
                        Text(
                            text = "Import Media Archive",
                            color = PrimaryText,
                            fontSize = 16.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Spacer(Modifier.height(8.dp))
                        Text(
                            text = "Import a media archive (.zip) from a previous backup.",
                            color = SecondaryText,
                            fontSize = 14.sp,
                            lineHeight = 20.sp,
                        )

                        if (mirrorStatus.isNotEmpty()) {
                            Spacer(Modifier.height(12.dp))
                            Text(
                                text = mirrorStatus,
                                color = if (mirrorCompleted) SuccessGreen else SecondaryText,
                                fontSize = 13.sp,
                            )
                        }

                        if (isMirroring) {
                            Spacer(Modifier.height(12.dp))
                            LinearProgressIndicator(
                                color = WizardAccent,
                                trackColor = WizardBgElevated,
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }

                        Spacer(Modifier.height(16.dp))

                        if (!isMirroring && !mirrorCompleted) {
                            WizardPrimaryButton(
                                text = "Choose Archive",
                                onClick = {
                                    mediaPicker.launch(arrayOf(
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

        if (mirrorCompleted) {
            WizardPrimaryButton(text = "Continue", onClick = viewModel::advanceFromMedia)
        } else if (!isMirroring) {
            WizardSecondaryButton(text = "Skip", onClick = viewModel::skipMedia)
        }
    }
}
