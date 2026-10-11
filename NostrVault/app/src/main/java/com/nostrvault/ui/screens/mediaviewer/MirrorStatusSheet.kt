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
import com.nostrvault.ui.theme.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun MirrorStatusSheet(
    sha256: String,
    mirrorStatus: Map<String, Boolean>,
    isLoading: Boolean,
    totalMirrors: Int,
    onDismiss: () -> Unit,
    onPushToMirrors: () -> Unit,
) {
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
                        "No mirrors configured. Add Blossom mirrors in Settings.",
                        color = SecondaryText,
                        fontSize = 14.sp,
                    )
                }
                else -> {
                    mirrorStatus.entries.sortedBy { it.key }.forEach { (mirror, available) ->
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
                        HorizontalDivider(color = Color.White.copy(alpha = 0.08f))
                    }

                    val missingCount = mirrorStatus.values.count { !it }
                    if (missingCount > 0) {
                        Spacer(Modifier.height(16.dp))
                        Button(
                            onClick = { onPushToMirrors(); onDismiss() },
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Icon(NostrVaultIcons.ArrowUp, contentDescription = null, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(8.dp))
                            Text("Push to Missing Mirrors")
                        }
                    }
                }
            }
        }
    }
}
