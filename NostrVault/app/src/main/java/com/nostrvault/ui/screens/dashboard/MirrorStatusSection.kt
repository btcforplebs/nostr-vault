package com.nostrvault.ui.screens.dashboard

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil.compose.AsyncImage
import com.nostrvault.ui.theme.*
import java.text.DateFormat
import java.util.Date

/**
 * Your Blossom servers and the files on this phone that one of them is
 * missing, with Copy, Stop and Retry and what happened to each file.
 * Self-contained: place it, and it loads and runs on its own.
 */
@Composable
fun MirrorStatusSection(
    modifier: Modifier = Modifier,
    viewModel: MediaCopyViewModel = hiltViewModel(),
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    var expanded by remember { mutableStateOf(true) }
    var showFiles by remember { mutableStateOf(false) }

    Surface(
        color = SecondaryGroupedBg,
        shape = RoundedCornerShape(12.dp),
        modifier = modifier.fillMaxWidth(),
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            // Header
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(
                    text = "Mirror Servers",
                    color = PrimaryText,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    text = "${state.servers.count { it.health == MediaServer.Health.WORKING }}/${state.servers.size} active",
                    color = SecondaryText,
                    fontSize = 12.sp,
                )
                Spacer(Modifier.width(8.dp))
                IconButton(
                    onClick = viewModel::load,
                    enabled = !state.isCopying,
                    modifier = Modifier.size(28.dp),
                ) {
                    Icon(
                        NostrVaultIcons.Refresh,
                        contentDescription = "Check again",
                        tint = SecondaryText,
                        modifier = Modifier.size(16.dp),
                    )
                }
                IconButton(
                    onClick = { expanded = !expanded },
                    modifier = Modifier.size(28.dp),
                ) {
                    Icon(
                        if (expanded) NostrVaultIcons.ChevronDown else NostrVaultIcons.Navigate,
                        contentDescription = if (expanded) "Collapse" else "Expand",
                        tint = SecondaryText,
                        modifier = Modifier.size(16.dp),
                    )
                }
            }

            AnimatedVisibility(visible = expanded) {
                Column {
                    if (state.servers.isEmpty()) {
                        Box(
                            contentAlignment = Alignment.Center,
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(vertical = 16.dp),
                        ) {
                            Text(
                                text = "No mirrors configured",
                                color = TertiaryText,
                                fontSize = 13.sp,
                            )
                        }
                    } else {
                        Spacer(Modifier.height(8.dp))
                        state.servers.forEach { server ->
                            MirrorRow(server, scanning = state.isScanning)
                            Spacer(Modifier.height(6.dp))
                        }
                        HorizontalDivider(color = TertiaryText.copy(alpha = 0.15f), modifier = Modifier.padding(vertical = 8.dp))
                        CopyBlock(
                            state = state,
                            showFiles = showFiles,
                            onToggleFiles = { showFiles = !showFiles },
                            onCopy = { showFiles = true; viewModel.startCopy() },
                            onStop = viewModel::stopCopy,
                            hostFor = viewModel::host,
                        )
                    }
                }
            }
        }
    }
}

/** Kept so the dashboard's current call still builds; the section now loads its own servers. */
@Deprecated("The section is self-contained now", ReplaceWith("MirrorStatusSection(modifier)"))
@Composable
fun MirrorStatusSection(
    @Suppress("UNUSED_PARAMETER") mirrors: List<MirrorInfo>,
    @Suppress("UNUSED_PARAMETER") onRefreshHealth: () -> Unit,
    modifier: Modifier = Modifier,
) = MirrorStatusSection(modifier = modifier)

@Composable
private fun CopyBlock(
    state: MediaCopyViewModel.UiState,
    showFiles: Boolean,
    onToggleFiles: () -> Unit,
    onCopy: () -> Unit,
    onStop: () -> Unit,
    hostFor: (String) -> String,
) {
    InfoLine("Files stored", state.filesStored?.toString() ?: "—")
    InfoLine(
        "Waiting to copy",
        state.scan?.let { (done, total) -> "Checking $done of $total" } ?: state.waiting?.toString() ?: "—",
    )
    Spacer(Modifier.height(8.dp))
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.weight(1f)) {
            Text("Copy to servers", color = PrimaryText, fontSize = 14.sp, fontWeight = FontWeight.Medium)
            Text(copyDetail(state), color = SecondaryText, fontSize = 12.sp)
        }
        Spacer(Modifier.width(8.dp))
        if (state.isCopying) {
            FilledTonalButton(onClick = onStop) { Text("Stop") }
        } else {
            FilledTonalButton(
                onClick = onCopy,
                enabled = !state.isScanning && (state.waiting ?: 0) > 0,
            ) { Text(if (state.hasFailures) "Retry" else "Copy") }
        }
    }
    state.copy?.let { (done, total) ->
        Spacer(Modifier.height(6.dp))
        LinearProgressIndicator(
            progress = { if (total > 0) done.toFloat() / total else 0f },
            modifier = Modifier.fillMaxWidth(),
        )
    }
    if (state.files.isNotEmpty()) {
        Spacer(Modifier.height(8.dp))
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .clickable(onClick = onToggleFiles)
                .padding(vertical = 6.dp),
        ) {
            Text(
                if (showFiles) "Hide files" else "Show files",
                color = MaterialTheme.colorScheme.primary,
                fontSize = 13.sp,
                fontWeight = FontWeight.Medium,
                modifier = Modifier.weight(1f),
            )
            Text("${state.files.size}", color = SecondaryText, fontSize = 12.sp)
        }
        AnimatedVisibility(visible = showFiles) {
            Column {
                state.files.forEach { file ->
                    HorizontalDivider(color = TertiaryText.copy(alpha = 0.15f))
                    CopyFileRow(file, hostFor)
                }
            }
        }
    }
    state.note?.let {
        Spacer(Modifier.height(8.dp))
        Text(it, color = SecondaryText, fontSize = 12.sp)
    }
}

private fun copyDetail(state: MediaCopyViewModel.UiState): String {
    state.copy?.let { (done, total) ->
        if (state.signing) return "Asking your signer to sign the upload. If it asks you to approve, approve it there."
        val failed = state.files.count { it.isFailed }
        val now = state.files.filter { it.status == MediaCopyFile.Status.Copying }
        val nowText = when (now.size) {
            0 -> "finishing"
            1 -> now[0].title()
            else -> "${now[0].title()} and ${now.size - 1} more"
        }
        return "Sent $done of $total${if (failed > 0) ", $failed failed" else ""}. Now: $nowText."
    }
    if (state.isScanning || state.waiting == null) return "Checking which files your servers are missing…"
    return when (val n = state.waiting) {
        0 -> "Every file is on your servers."
        1 -> "1 file is only on this phone."
        else -> "$n files are only on this phone."
    }
}

private fun MediaCopyFile.title(): String = "${kind.label} · ${formatSize(size)}"

@Composable
private fun InfoLine(title: String, value: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 3.dp)) {
        Text(title, color = PrimaryText, fontSize = 14.sp, modifier = Modifier.weight(1f))
        Text(value, color = SecondaryText, fontSize = 14.sp)
    }
}

@Composable
private fun CopyFileRow(file: MediaCopyFile, hostFor: (String) -> String) {
    Row(
        verticalAlignment = Alignment.Top,
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 8.dp),
    ) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .size(40.dp)
                .clip(RoundedCornerShape(6.dp))
                .background(TertiaryText.copy(alpha = 0.15f)),
        ) {
            if (file.kind == MediaCopyFile.Kind.PHOTO || file.kind == MediaCopyFile.Kind.GIF) {
                AsyncImage(
                    model = file.file,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize(),
                )
            } else {
                Icon(
                    when (file.kind) {
                        MediaCopyFile.Kind.VIDEO -> NostrVaultIcons.Video
                        MediaCopyFile.Kind.AUDIO -> NostrVaultIcons.Music
                        else -> NostrVaultIcons.Document
                    },
                    contentDescription = null,
                    tint = SecondaryText,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(file.title(), color = PrimaryText, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
            val added = "Added " + DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(file.addedMillis))
            val missing = file.servers.joinToString { hostFor(it) }
            Text(
                if (missing.isEmpty()) added else "$added · Missing on $missing",
                color = SecondaryText,
                fontSize = 12.sp,
            )
            (file.status as? MediaCopyFile.Status.Failed)?.failures?.forEach { failure ->
                Text(
                    if (file.servers.size > 1) "${hostFor(failure.server)}: ${failure.reason}" else failure.reason,
                    color = ErrorRed,
                    fontSize = 12.sp,
                )
            }
        }
        Spacer(Modifier.width(8.dp))
        when (file.status) {
            MediaCopyFile.Status.Waiting -> Text("Waiting", color = SecondaryText, fontSize = 12.sp)
            MediaCopyFile.Status.Copying -> Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(strokeWidth = 1.5.dp, modifier = Modifier.size(12.dp))
                Spacer(Modifier.width(6.dp))
                Text("Sending", color = SecondaryText, fontSize = 12.sp)
            }
            MediaCopyFile.Status.Copied -> Text("Copied", color = SuccessGreen, fontSize = 12.sp)
            is MediaCopyFile.Status.Failed -> Text("Failed", color = ErrorRed, fontSize = 12.sp)
        }
    }
}

@Composable
private fun MirrorRow(server: MediaServer, scanning: Boolean) {
    val statusColor = when (server.health) {
        MediaServer.Health.WORKING -> SuccessGreen
        MediaServer.Health.OFFLINE -> ErrorRed
        MediaServer.Health.ANSWERS, MediaServer.Health.UNKNOWN -> WarningYellow
    }

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
    ) {
        // Health dot
        Box(
            modifier = Modifier
                .size(8.dp)
                .background(statusColor, CircleShape),
        )
        Spacer(Modifier.width(10.dp))

        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = server.host,
                color = PrimaryText,
                fontSize = 13.sp,
            )
        }

        if (scanning && server.health == MediaServer.Health.UNKNOWN) {
            CircularProgressIndicator(
                color = WarningYellow,
                strokeWidth = 1.5.dp,
                modifier = Modifier.size(12.dp),
            )
        } else {
            Text(
                text = when (server.health) {
                    MediaServer.Health.WORKING -> "Has your files"
                    MediaServer.Health.ANSWERS -> "Answers, holds none yet"
                    MediaServer.Health.OFFLINE -> "Not answering"
                    MediaServer.Health.UNKNOWN -> "Not checked yet"
                },
                color = SecondaryText,
                fontSize = 11.sp,
            )
        }
    }
}
