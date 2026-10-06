package com.nostrvault.ui.screens.dashboard

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.service.CacheBreakdown
import com.nostrvault.service.StatsService
import com.nostrvault.ui.theme.*
import java.io.File

private val ImageCacheColor = Color(0xFF5E5CE6)
private val VideoCacheColor = Color(0xFFFF375F)
private val OtherCacheColor = Color(0xFF64D2FF)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CacheBreakdownSheet(
    statsService: StatsService,
    cacheDir: String?,
    cacheTTLDays: Int = 3,
    onDismiss: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    var breakdown by remember { mutableStateOf(CacheBreakdown()) }
    var isClearing by remember { mutableStateOf(false) }
    var showConfirmDialog by remember { mutableStateOf(false) }

    LaunchedEffect(cacheDir) {
        if (cacheDir != null) {
            breakdown = statsService.calculateCacheBreakdown(cacheDir)
        }
    }

    val totalSize = breakdown.imageSize + breakdown.videoSize + breakdown.otherSize
    val totalCount = breakdown.imageCount + breakdown.videoCount + breakdown.otherCount

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = WindowBackground,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
                .padding(bottom = 32.dp),
        ) {
            // Header
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth().padding(bottom = 16.dp),
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = "Media Cache",
                        color = PrimaryText,
                        fontSize = 18.sp,
                        fontWeight = FontWeight.Bold,
                    )
                    Text(
                        text = "$totalCount files, ${formatSize(totalSize)}",
                        color = SecondaryText,
                        fontSize = 13.sp,
                    )
                }
            }

            Surface(
                color = SecondaryGroupedBg,
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(modifier = Modifier.padding(16.dp)) {
                    BlobTypeRow(
                        label = "Images",
                        icon = NostrVaultIcons.Media,
                        color = ImageCacheColor,
                        count = breakdown.imageCount,
                        size = breakdown.imageSize,
                        total = totalSize,
                    )
                    HorizontalDivider(color = TertiaryText.copy(alpha = 0.2f), modifier = Modifier.padding(vertical = 4.dp))
                    BlobTypeRow(
                        label = "Videos",
                        icon = NostrVaultIcons.Video,
                        color = VideoCacheColor,
                        count = breakdown.videoCount,
                        size = breakdown.videoSize,
                        total = totalSize,
                    )
                    HorizontalDivider(color = TertiaryText.copy(alpha = 0.2f), modifier = Modifier.padding(vertical = 4.dp))
                    BlobTypeRow(
                        label = "Other",
                        icon = NostrVaultIcons.Document,
                        color = OtherCacheColor,
                        count = breakdown.otherCount,
                        size = breakdown.otherSize,
                        total = totalSize,
                    )
                }
            }

            Spacer(Modifier.height(12.dp))

            // Cache policy + file-age metadata
            Surface(
                color = SecondaryGroupedBg,
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(modifier = Modifier.padding(16.dp)) {
                    CacheMetaRow(
                        label = "Expires after",
                        value = if (cacheTTLDays <= 0) "Never" else "$cacheTTLDays days",
                    )
                    breakdown.oldestDate?.let {
                        HorizontalDivider(color = TertiaryText.copy(alpha = 0.2f), modifier = Modifier.padding(vertical = 4.dp))
                        CacheMetaRow(label = "Oldest file", value = relativeAge(it))
                    }
                    breakdown.newestDate?.let {
                        HorizontalDivider(color = TertiaryText.copy(alpha = 0.2f), modifier = Modifier.padding(vertical = 4.dp))
                        CacheMetaRow(label = "Newest file", value = relativeAge(it))
                    }
                }
            }

            Spacer(Modifier.height(16.dp))

            // Clear cache button
            Button(
                onClick = { showConfirmDialog = true },
                colors = ButtonDefaults.buttonColors(containerColor = ErrorRed),
                enabled = totalCount > 0 && !isClearing,
                modifier = Modifier.fillMaxWidth(),
            ) {
                if (isClearing) {
                    CircularProgressIndicator(
                        color = PrimaryText,
                        strokeWidth = 2.dp,
                        modifier = Modifier.size(16.dp),
                    )
                    Spacer(Modifier.width(8.dp))
                }
                Text(if (isClearing) "Clearing..." else "Clear Cache")
            }
        }
    }

    if (showConfirmDialog) {
        AlertDialog(
            onDismissRequest = { showConfirmDialog = false },
            title = { Text("Clear Media Cache?") },
            text = { Text("This will remove $totalCount cached media files (${formatSize(totalSize)}). They will be re-downloaded when needed.") },
            confirmButton = {
                TextButton(
                    onClick = {
                        showConfirmDialog = false
                        isClearing = true
                        if (cacheDir != null) {
                            val dir = File(cacheDir)
                            if (dir.exists()) {
                                dir.walkBottomUp().forEach { file ->
                                    if (file.isFile) file.delete()
                                }
                            }
                        }
                        breakdown = CacheBreakdown()
                        isClearing = false
                    },
                ) {
                    Text("Clear", color = ErrorRed)
                }
            },
            dismissButton = {
                TextButton(onClick = { showConfirmDialog = false }) {
                    Text("Cancel")
                }
            },
            containerColor = SecondaryGroupedBg,
            titleContentColor = PrimaryText,
            textContentColor = SecondaryText,
        )
    }
}

@Composable
private fun CacheMetaRow(label: String, value: String) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp),
    ) {
        Text(label, color = SecondaryText, fontSize = 14.sp, modifier = Modifier.weight(1f))
        Text(value, color = PrimaryText, fontSize = 14.sp, fontWeight = FontWeight.Medium)
    }
}

/** Human-readable age of a file timestamp (ms), e.g. "3 days ago". */
private fun relativeAge(timestampMs: Long): String {
    val deltaMs = (System.currentTimeMillis() - timestampMs).coerceAtLeast(0L)
    val mins = deltaMs / 60_000
    val hours = mins / 60
    val days = hours / 24
    return when {
        days >= 1 -> if (days == 1L) "1 day ago" else "$days days ago"
        hours >= 1 -> if (hours == 1L) "1 hour ago" else "$hours hours ago"
        mins >= 1 -> if (mins == 1L) "1 minute ago" else "$mins minutes ago"
        else -> "Just now"
    }
}
