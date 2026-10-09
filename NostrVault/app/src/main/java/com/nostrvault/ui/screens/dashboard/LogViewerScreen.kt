package com.nostrvault.ui.screens.dashboard

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.relay.RelayLogParser
import com.nostrvault.ui.theme.*
import java.text.SimpleDateFormat
import java.util.Locale

private enum class LogFilter(val label: String) {
    ALL("All"),
    INFO_PLUS("Info+"),
    WARN_PLUS("Warn+"),
    ERRORS("Errors"),
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LogViewerScreen(
    logs: List<RelayLogParser.LogEntry>,
    onBack: () -> Unit,
) {
    var activeFilter by remember { mutableStateOf(LogFilter.ALL) }
    val context = LocalContext.current
    val listState = rememberLazyListState()
    val timeFormat = remember { SimpleDateFormat("HH:mm:ss", Locale.getDefault()) }

    val filteredLogs = remember(logs, activeFilter) {
        when (activeFilter) {
            LogFilter.ALL -> logs
            LogFilter.INFO_PLUS -> logs.filter { it.level != "DEBUG" }
            LogFilter.WARN_PLUS -> logs.filter { it.level == "WARN" || it.level == "ERROR" }
            LogFilter.ERRORS -> logs.filter { it.level == "ERROR" }
        }
    }

    // Auto-scroll to bottom on new entries
    LaunchedEffect(filteredLogs.size) {
        if (filteredLogs.isNotEmpty()) {
            listState.animateScrollToItem(filteredLogs.size - 1)
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Relay Logs") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(NostrVaultIcons.Back, contentDescription = "Back")
                    }
                },
                actions = {
                    IconButton(onClick = {
                        val text = logs.joinToString("\n") { entry ->
                            "[${entry.level}] ${entry.message}"
                        }
                        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                        clipboard.setPrimaryClip(ClipData.newPlainText("Relay Logs", text))
                    }) {
                        Icon(NostrVaultIcons.Copy, "Copy logs", tint = SecondaryText)
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
                .padding(padding),
        ) {
            // Filter row
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp)
                    .horizontalScroll(rememberScrollState()),
            ) {
                LogFilter.entries.forEach { filter ->
                    val selected = activeFilter == filter
                    FilterChip(
                        selected = selected,
                        onClick = { activeFilter = filter },
                        label = {
                            Text(
                                text = filter.label,
                                fontSize = 12.sp,
                            )
                        },
                        colors = FilterChipDefaults.filterChipColors(
                            selectedContainerColor = LocalNostrVaultColors.current.primary.copy(alpha = 0.2f),
                            selectedLabelColor = LocalNostrVaultColors.current.primary,
                            containerColor = SecondaryGroupedBg,
                            labelColor = SecondaryText,
                        ),
                    )
                }

                Spacer(Modifier.weight(1f))

                Text(
                    text = "${filteredLogs.size} entries",
                    color = TertiaryText,
                    fontSize = 12.sp,
                    modifier = Modifier.align(Alignment.CenterVertically),
                )
            }

            // Log list
            if (filteredLogs.isEmpty()) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(32.dp),
                ) {
                    Text(
                        text = "No log entries",
                        color = TertiaryText,
                        fontSize = 14.sp,
                        fontFamily = FontFamily.Monospace,
                    )
                }
            } else {
                LazyColumn(
                    state = listState,
                    modifier = Modifier.fillMaxSize(),
                ) {
                    items(filteredLogs, key = { it.id }) { entry ->
                        FullLogEntryRow(entry, timeFormat)
                    }
                }
            }
        }
    }
}

@Composable
private fun FullLogEntryRow(
    entry: RelayLogParser.LogEntry,
    timeFormat: SimpleDateFormat,
) {
    val levelColor = when (entry.level) {
        "ERROR" -> ErrorRed
        "WARN" -> WarningYellow
        "DEBUG" -> TertiaryText
        else -> SuccessGreen
    }

    val levelBgColor = when (entry.level) {
        "ERROR" -> ErrorRed.copy(alpha = 0.15f)
        "WARN" -> WarningYellow.copy(alpha = 0.1f)
        else -> Color.Transparent
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(levelBgColor)
            .padding(horizontal = 16.dp, vertical = 4.dp),
    ) {
        // Timestamp
        Text(
            text = timeFormat.format(entry.timestamp),
            color = TertiaryText,
            fontSize = 10.sp,
            fontFamily = FontFamily.Monospace,
        )

        Spacer(Modifier.width(8.dp))

        // Level badge
        Surface(
            color = levelColor.copy(alpha = 0.2f),
            shape = RoundedCornerShape(3.dp),
        ) {
            Text(
                text = entry.level.take(4),
                color = levelColor,
                fontSize = 9.sp,
                fontWeight = FontWeight.Bold,
                fontFamily = FontFamily.Monospace,
                modifier = Modifier.padding(horizontal = 4.dp, vertical = 1.dp),
            )
        }

        Spacer(Modifier.width(8.dp))

        // Message: long-press selects and copies, like iOS .textSelection(.enabled).
        SelectionContainer(modifier = Modifier.weight(1f)) {
            Text(
                text = entry.message,
                color = PrimaryText.copy(alpha = 0.9f),
                fontSize = 11.sp,
                fontFamily = FontFamily.Monospace,
            )
        }
    }
}
