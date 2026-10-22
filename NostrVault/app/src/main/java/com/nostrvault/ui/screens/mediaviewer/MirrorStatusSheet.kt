package com.nostrvault.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.hilt.navigation.compose.hiltViewModel
import com.nostrvault.service.BlobCopyOutcome
import com.nostrvault.ui.screens.dashboard.MediaCopyViewModel
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun MirrorStatusSheet(
    sha256: String,
    mirrorStatus: Map<String, Boolean>,
    isLoading: Boolean,
    totalMirrors: Int,
    onDismiss: () -> Unit,
    /** Kept for the caller; the sheet now copies in place and shows each server's answer. */
    @Suppress("UNUSED_PARAMETER") onPushToMirrors: () -> Unit,
    copier: MediaCopyViewModel = hiltViewModel(),
) {
    val scope = rememberCoroutineScope()
    var copying by remember(sha256) { mutableStateOf(false) }
    /** What the last copy said, per server; copied ones read as Available. */
    var results by remember(sha256) { mutableStateOf<Map<String, BlobCopyOutcome>>(emptyMap()) }
    var sheetNote by remember(sha256) { mutableStateOf<String?>(null) }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
                .padding(bottom = 32.dp),
        ) {
            Text("Blossom Mirrors", fontWeight = FontWeight.Bold, fontSize = 18.sp, color = PrimaryText)
            Spacer(Modifier.height(2.dp))
            Text(
                text = sha256.take(16) + "…",
                fontSize = 11.sp,
                color = TertiaryText,
                fontFamily = FontFamily.Monospace,
            )
            Spacer(Modifier.height(16.dp))

            when {
                isLoading -> {
                    Box(
                        contentAlignment = Alignment.Center,
                        modifier = Modifier.fillMaxWidth().padding(vertical = 24.dp),
                    ) {
                        CircularProgressIndicator()
                    }
                }
                totalMirrors == 0 -> {
                    Text(
                        "No mirrors configured. Add a server in Settings → Media Servers.",
                        color = SecondaryText,
                        fontSize = 14.sp,
                    )
                }
                else -> {
                    mirrorStatus.entries.sortedBy { it.key }.forEach { (mirror, found) ->
                        val available = found || results[mirror] == BlobCopyOutcome.Copied
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(vertical = 10.dp),
                        ) {
                            Icon(
                                imageVector = if (available) NostrVaultIcons.Check else NostrVaultIcons.Dismiss,
                                contentDescription = null,
                                tint = if (available) Color(0xFF4CAF50) else Color(0xFFE53935),
                                modifier = Modifier.size(20.dp),
                            )
                            Spacer(Modifier.width(12.dp))
                            Column(modifier = Modifier.weight(1f)) {
                                val host = runCatching { java.net.URL(mirror).host }.getOrNull() ?: mirror
                                Text(host, color = PrimaryText, fontSize = 14.sp, fontWeight = FontWeight.Medium)
                                Text(
                                    mirror,
                                    color = TertiaryText,
                                    fontSize = 11.sp,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                            Spacer(Modifier.width(8.dp))
                            Text(
                                text = if (available) "Available" else "Not Found",
                                color = if (available) Color(0xFF4CAF50) else SecondaryText,
                                fontSize = 11.sp,
                                fontWeight = FontWeight.Medium,
                            )
                        }
                        (results[mirror] as? BlobCopyOutcome.Failed)?.let { failed ->
                            Text(
                                failed.reason,
                                color = Color(0xFFE53935),
                                fontSize = 12.sp,
                                modifier = Modifier.padding(start = 32.dp, bottom = 8.dp),
                            )
                        }
                        HorizontalDivider(color = Color.White.copy(alpha = 0.08f))
                    }

                    val missingCount = mirrorStatus.count { (mirror, found) -> !found && results[mirror] != BlobCopyOutcome.Copied }
                    if (missingCount > 0) {
                        Spacer(Modifier.height(16.dp))
                        Button(
                            onClick = {
                                copying = true
                                sheetNote = null
                                scope.launch {
                                    val outcome = copier.copyOne(sha256)
                                    if (outcome == null) sheetNote = "This file isn't on this phone, so there is nothing to copy from."
                                    else results = results + outcome
                                    copying = false
                                }
                            },
                            enabled = !copying,
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            if (copying) {
                                CircularProgressIndicator(strokeWidth = 1.5.dp, modifier = Modifier.size(16.dp))
                            } else {
                                Icon(NostrVaultIcons.ArrowUp, contentDescription = null, modifier = Modifier.size(16.dp))
                            }
                            Spacer(Modifier.width(8.dp))
                            Text(
                                when {
                                    copying -> "Copying…"
                                    results.values.any { it is BlobCopyOutcome.Failed } -> "Retry"
                                    missingCount == 1 -> "Copy to the missing server"
                                    else -> "Copy to $missingCount missing servers"
                                },
                            )
                        }
                    }
                    sheetNote?.let {
                        Spacer(Modifier.height(8.dp))
                        Text(it, color = SecondaryText, fontSize = 12.sp)
                    }
                }
            }
        }
    }
}
