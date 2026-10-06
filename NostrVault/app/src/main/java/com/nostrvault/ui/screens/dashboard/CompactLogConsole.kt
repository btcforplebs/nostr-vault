package com.nostrvault.ui.screens.dashboard

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.relay.PlainLog
import com.nostrvault.relay.RelayLogParser
import com.nostrvault.ui.theme.*

private val ConsoleBg = Color(0xFF0D0D12)
private val ConsoleBorder = Color(0xFF2A2A35)

/**
 * The dashboard console in plain language: a status pill, the latest items
 * from [PlainLog] (repeats folded into a count, hints under problems), and
 * "View All" into the Relay Activity screen. The raw log is Settings › Logs.
 */
@Composable
fun CompactLogConsole(
    logs: List<RelayLogParser.LogEntry>,
    onViewAll: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val items = remember(logs) { PlainLog.summarize(logs) }
    val displayItems = items.takeLast(30)
    val health = remember(items) { PlainLog.health(items) }
    val listState = rememberLazyListState()

    // A repeat moves its item to the end without changing the size, so
    // follow the last key rather than the count.
    val lastKey = displayItems.lastOrNull()?.key
    LaunchedEffect(lastKey) {
        if (displayItems.isNotEmpty()) {
            listState.animateScrollToItem(displayItems.size - 1)
        }
    }

    Surface(
        color = ConsoleBg,
        shape = RoundedCornerShape(12.dp),
        modifier = modifier
            .fillMaxWidth()
            .border(1.dp, ConsoleBorder, RoundedCornerShape(12.dp)),
    ) {
        Column {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .background(ConsoleBorder)
                    .padding(start = 12.dp, end = 4.dp, top = 4.dp, bottom = 4.dp),
            ) {
                Text(
                    text = "RELAY ACTIVITY",
                    color = SecondaryText,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Bold,
                    fontFamily = FontFamily.Monospace,
                    letterSpacing = 1.sp,
                )
                Spacer(Modifier.width(8.dp))
                RelayHealthPill(health)
                Spacer(Modifier.weight(1f))
                TextButton(
                    onClick = onViewAll,
                    contentPadding = PaddingValues(horizontal = 8.dp, vertical = 2.dp),
                ) {
                    Text(
                        text = "View All",
                        color = LocalNostrVaultColors.current.primary,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            }

            if (displayItems.isEmpty()) {
                RelayActivityEmpty(compact = true, modifier = Modifier.height(140.dp))
            } else {
                LazyColumn(
                    state = listState,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(140.dp)
                        .padding(vertical = 2.dp),
                ) {
                    items(displayItems, key = { it.key }) { item ->
                        RelayActivityRow(item, compact = true)
                    }
                }
            }
        }
    }
}
