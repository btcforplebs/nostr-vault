package com.nostrvault.ui.screens.dashboard

import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.relay.PlainLog
import com.nostrvault.relay.RelayLogParser
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * "View All" from the dashboard console: the whole plain-language relay log
 * with a status banner, a Needs attention filter, privacy-safe Copy/Export,
 * and a way through to the raw log (Settings › Logs) for power users.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RelayActivityScreen(
    logs: List<RelayLogParser.LogEntry>,
    onBack: () -> Unit,
    onOpenFullLogs: () -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val colors = LocalNostrVaultColors.current
    var issuesOnly by remember { mutableStateOf(false) }

    val items = remember(logs) { PlainLog.summarize(logs) }
    val health = remember(items) { PlainLog.health(items) }
    val shown = if (issuesOnly) items.filter { it.severity != PlainLog.Severity.GOOD } else items

    // Export writes a .txt the user picks a place for. The text is built when
    // the save happens, from the items on screen at that moment.
    val exportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("text/plain"),
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        val text = RelayActivityReport.text(items)
        scope.launch {
            val ok = withContext(Dispatchers.IO) {
                runCatching {
                    context.contentResolver.openOutputStream(uri)?.use { it.write(text.toByteArray()) } != null
                }.getOrDefault(false)
            }
            Toast.makeText(
                context,
                if (ok) "Report saved" else "Couldn't save the report",
                Toast.LENGTH_SHORT,
            ).show()
        }
    }

    val listState = rememberLazyListState()
    val lastKey = shown.lastOrNull()?.key
    LaunchedEffect(lastKey, issuesOnly) {
        if (shown.isNotEmpty()) listState.animateScrollToItem(shown.size - 1)
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Relay Activity") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(NostrVaultIcons.Back, contentDescription = "Back")
                    }
                },
                actions = {
                    IconButton(
                        onClick = {
                            RelayActivityReport.copy(context, items)
                            Toast.makeText(context, "Report copied", Toast.LENGTH_SHORT).show()
                        },
                        enabled = items.isNotEmpty(),
                    ) {
                        Icon(NostrVaultIcons.Copy, "Copy report", tint = if (items.isNotEmpty()) colors.primary else TertiaryText)
                    }
                    IconButton(
                        onClick = { exportLauncher.launch(RelayActivityReport.fileName()) },
                        enabled = items.isNotEmpty(),
                    ) {
                        Icon(NostrVaultIcons.Share, "Export report", tint = if (items.isNotEmpty()) colors.primary else TertiaryText)
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
            StatusBanner(health, items)

            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
            ) {
                listOf(false to "Everything", true to "Needs attention").forEach { (value, label) ->
                    FilterChip(
                        selected = issuesOnly == value,
                        onClick = { issuesOnly = value },
                        label = { Text(label, fontSize = 13.sp) },
                        colors = FilterChipDefaults.filterChipColors(
                            selectedContainerColor = colors.primary.copy(alpha = 0.2f),
                            selectedLabelColor = colors.primary,
                            containerColor = SecondaryGroupedBg,
                            labelColor = SecondaryText,
                        ),
                    )
                }
            }

            HorizontalDivider(color = SeparatorColor)

            Box(Modifier.weight(1f).fillMaxWidth()) {
                when {
                    shown.isNotEmpty() -> LazyColumn(state = listState, modifier = Modifier.fillMaxSize()) {
                        items(shown, key = { it.key }) { RelayActivityRow(it) }
                    }
                    issuesOnly && items.isNotEmpty() -> Text(
                        "Nothing needs attention",
                        color = SecondaryText,
                        fontSize = 16.sp,
                        modifier = Modifier.align(Alignment.Center),
                    )
                    else -> RelayActivityEmpty(modifier = Modifier.align(Alignment.Center))
                }
            }

            HorizontalDivider(color = SeparatorColor)

            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .navigationBarsPadding()
                    .padding(start = 16.dp, end = 4.dp, top = 2.dp, bottom = 2.dp),
            ) {
                RelayPrivacyNote(Modifier.weight(1f))
                TextButton(onClick = onOpenFullLogs) {
                    Text("Open full logs", color = colors.primary, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }
}

@Composable
private fun StatusBanner(health: PlainLog.Severity, items: List<PlainLog.Item>) {
    val lastUp = items.firstOrNull { it.key == "running" }?.lastSeen?.time ?: Long.MIN_VALUE
    val top = items.lastOrNull {
        health != PlainLog.Severity.GOOD && it.severity == health && it.lastSeen.time >= lastUp
    }
    val detail = when {
        top == null -> "Your relay is running normally."
        top.hint != null -> "${top.title}. ${top.hint}"
        else -> top.title
    }
    val shape = RoundedCornerShape(10.dp)

    Row(
        verticalAlignment = Alignment.Top,
        modifier = Modifier
            .padding(start = 16.dp, end = 16.dp, top = 12.dp)
            .fillMaxWidth()
            .background(health.tint.copy(alpha = 0.10f), shape)
            .border(1.dp, health.tint.copy(alpha = 0.25f), shape)
            .padding(14.dp),
    ) {
        Icon(health.icon, contentDescription = null, tint = health.tint, modifier = Modifier.size(24.dp))
        Spacer(Modifier.width(12.dp))
        Column {
            Text(
                health.summary,
                color = PrimaryText,
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.semantics { heading() },
            )
            Spacer(Modifier.height(3.dp))
            Text(detail, color = SecondaryText, fontSize = 13.sp)
        }
    }
}
