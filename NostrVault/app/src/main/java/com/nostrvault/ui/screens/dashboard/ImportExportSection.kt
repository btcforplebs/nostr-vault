package com.nostrvault.ui.screens.dashboard

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.*

@Composable
fun ImportExportSection(
    isImporting: Boolean,
    importProgress: Float,
    importStatusMessage: String,
    importCompleted: Boolean,
    isExportingJsonl: Boolean,
    isExportingMedia: Boolean,
    isImportingBlossom: Boolean,
    onImportNotes: () -> Unit,
    onImportBlossom: () -> Unit,
    onExportJsonl: () -> Unit,
    onExportMedia: () -> Unit,
    onDismissImport: () -> Unit,
) {
    Column(modifier = Modifier.fillMaxWidth()) {
        Text(
            text = "Actions",
            color = PrimaryText,
            fontSize = 16.sp,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(bottom = 12.dp),
        )

        // Import progress section (visible during import)
        if (isImporting || importCompleted) {
            Surface(
                color = SecondaryGroupedBg,
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        if (!importCompleted) {
                            CircularProgressIndicator(
                                color = LocalNostrVaultColors.current.primary,
                                strokeWidth = 2.dp,
                                modifier = Modifier.size(16.dp),
                            )
                            Spacer(Modifier.width(8.dp))
                        }
                        Text(
                            text = if (importCompleted) "Import Complete" else "Importing Notes...",
                            color = if (importCompleted) SuccessGreen else PrimaryText,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.SemiBold,
                            modifier = Modifier.weight(1f),
                        )
                        Text(
                            text = "${(importProgress * 100).toInt()}%",
                            color = SecondaryText,
                            fontSize = 13.sp,
                        )
                    }

                    Spacer(Modifier.height(8.dp))

                    // Progress bar
                    val animatedProgress by animateFloatAsState(
                        targetValue = importProgress,
                        animationSpec = Motion.fade(),
                        label = "importProgress",
                    )
                    LinearProgressIndicator(
                        progress = { animatedProgress },
                        color = if (importCompleted) SuccessGreen else LocalNostrVaultColors.current.primary,
                        trackColor = TertiaryText.copy(alpha = 0.2f),
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(4.dp),
                    )

                    if (importStatusMessage.isNotBlank()) {
                        Spacer(Modifier.height(8.dp))
                        Text(
                            text = importStatusMessage,
                            color = SecondaryText,
                            fontSize = 12.sp,
                        )
                    }

                    if (importCompleted) {
                        Spacer(Modifier.height(8.dp))
                        TextButton(
                            onClick = onDismissImport,
                            contentPadding = PaddingValues(horizontal = 8.dp),
                        ) {
                            Text("Dismiss", color = SecondaryText, fontSize = 12.sp)
                        }
                    }
                }
            }

            Spacer(Modifier.height(12.dp))
        }

        // Action buttons grid: imports on top, exports below (iOS actionGrid)
        Row(
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            ActionButton(
                icon = NostrVaultIcons.Import,
                title = "Import Notes",
                isLoading = isImporting,
                enabled = !isImporting && !isExportingJsonl && !isExportingMedia,
                modifier = Modifier.weight(1f),
                onClick = onImportNotes,
            )
            // Pulls your media from the Blossom mirrors into this device's relay.
            ActionButton(
                icon = NostrVaultIcons.Blossom,
                title = "Import Blossom",
                isLoading = isImportingBlossom,
                enabled = !isImportingBlossom,
                modifier = Modifier.weight(1f),
                onClick = onImportBlossom,
            )
        }
        Spacer(Modifier.height(12.dp))
        Row(
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            ActionButton(
                icon = NostrVaultIcons.Backup,
                title = "Export JSONL",
                isLoading = isExportingJsonl,
                enabled = !isImporting && !isExportingJsonl && !isExportingMedia,
                modifier = Modifier.weight(1f),
                onClick = onExportJsonl,
            )
            ActionButton(
                icon = NostrVaultIcons.UploadIcon,
                title = "Export Media",
                isLoading = isExportingMedia,
                enabled = !isImporting && !isExportingJsonl && !isExportingMedia,
                modifier = Modifier.weight(1f),
                onClick = onExportMedia,
            )
        }
    }
}
