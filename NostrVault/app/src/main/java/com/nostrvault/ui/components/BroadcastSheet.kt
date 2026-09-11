package com.nostrvault.ui.components

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedNote
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.add
import kotlinx.serialization.json.addJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray

/** Default blastr relays when none are configured (mirrors iOS). */
private val DEFAULT_BLASTR_RELAYS = listOf(
    "wss://relay.primal.net",
    "wss://nos.lol",
)

private val prettyJson = Json { prettyPrint = true }

/** Recursively sort object keys so the rendered JSON matches iOS (.sortedKeys). */
private fun sortJsonKeys(el: JsonElement): JsonElement = when (el) {
    is JsonObject -> JsonObject(el.toSortedMap().mapValues { sortJsonKeys(it.value) })
    is JsonArray -> JsonArray(el.map { sortJsonKeys(it) })
    else -> el
}

/** Pretty-print (and key-sort) a raw event JSON string; returns the input on parse failure. */
private fun formatEventJson(raw: String): String = try {
    prettyJson.encodeToString(JsonElement.serializer(), sortJsonKeys(prettyJson.parseToJsonElement(raw)))
} catch (_: Exception) {
    raw
}

/** Build a minimal event JSON from the FeedNote fields (used until the signed event is fetched). */
private fun minimalEventJson(note: FeedNote): String = buildJsonObject {
    put("id", note.id)
    put("pubkey", note.pubkey)
    put("created_at", note.createdAt.time / 1000)
    put("kind", note.kind)
    putJsonArray("tags") {
        note.tags.forEach { tag -> addJsonArray { tag.forEach { add(it) } } }
    }
    put("content", note.content)
}.toString()

private fun middleTruncate(s: String, edge: Int = 14): String =
    if (s.length <= edge * 2 + 1) s else "${s.take(edge)}…${s.takeLast(edge)}"

/**
 * Event info / broadcast sheet. Full port of iOS EventBroadcastSheet:
 * shows event ids (hex, note1, nevent, share link), the full signed raw event
 * JSON (fetched if not cached), and a per-relay broadcast section.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BroadcastSheet(
    note: FeedNote,
    sheetState: SheetState,
    feedService: FeedService,
    nostrService: NostrService,
    configStore: ConfigStore,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    val colors = LocalNostrVaultColors.current
    val scope = rememberCoroutineScope()

    val note1 = remember(note.id) { HavenBridge.hexToNote1(note.id) ?: note.id }
    val nevent = remember(note.id) { HavenBridge.encodeNevent(note.id, note.pubkey, note.kind) ?: note1 }
    val shareLink = remember(nevent) { threadLink(nevent) }

    val blastrRelays = remember {
        configStore.config.value.activeBlastrRelays.ifEmpty { DEFAULT_BLASTR_RELAYS }
    }

    // Raw event: prefer the cached signed event, otherwise fetch it from relays.
    var fullEventJson by remember { mutableStateOf(feedService.getCachedRawEvent(note.id)) }
    var isFetching by remember { mutableStateOf(fullEventJson == null) }

    LaunchedEffect(note.id) {
        if (fullEventJson != null) return@LaunchedEffect
        nostrService.fetchNoteById(
            id = note.id,
            onRawEvent = { id, raw ->
                scope.launch(Dispatchers.Main.immediate) {
                    if (id == note.id && fullEventJson == null) {
                        fullEventJson = raw
                        isFetching = false
                    }
                }
            },
            onResult = {
                scope.launch(Dispatchers.Main.immediate) { isFetching = false }
            },
        )
    }

    val displayedJson = remember(fullEventJson) {
        formatEventJson(fullEventJson ?: minimalEventJson(note))
    }

    // Broadcast progress state.
    var isBroadcasting by remember { mutableStateOf(false) }
    var pendingRelays by remember { mutableStateOf(emptySet<String>()) }
    var succeededRelays by remember { mutableStateOf(emptySet<String>()) }
    var failedRelays by remember { mutableStateOf(emptySet<String>()) }
    var broadcastResult by remember { mutableStateOf<String?>(null) }

    fun broadcast() {
        val json = fullEventJson ?: return
        isBroadcasting = true
        broadcastResult = null
        succeededRelays = emptySet()
        failedRelays = emptySet()
        pendingRelays = blastrRelays.toSet()
        val total = blastrRelays.size
        nostrService.broadcastRawEvent(json) { relay, success ->
            scope.launch(Dispatchers.Main.immediate) {
                pendingRelays = pendingRelays - relay
                if (success) succeededRelays = succeededRelays + relay
                else failedRelays = failedRelays + relay
                if (pendingRelays.isEmpty()) {
                    isBroadcasting = false
                    val count = succeededRelays.size
                    broadcastResult = if (count == total) {
                        "Broadcast to all $count relays"
                    } else {
                        "Broadcast to $count/$total relays"
                    }
                }
            }
        }
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = SecondaryGroupedBg,
        dragHandle = { BottomSheetDefaults.DragHandle(color = SecondaryText) },
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .padding(bottom = 32.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            // Title bar — "Event Info" with a leading Done action (iOS inline nav bar).
            Box(modifier = Modifier.fillMaxWidth()) {
                TextButton(
                    onClick = onDismiss,
                    contentPadding = PaddingValues(0.dp),
                    modifier = Modifier.align(Alignment.CenterStart),
                ) {
                    Text("Done", color = colors.primary, fontSize = 16.sp)
                }
                Text(
                    text = "Event Info",
                    color = PrimaryText,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 17.sp,
                    modifier = Modifier.align(Alignment.Center),
                )
            }

            // EVENT ID section.
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("EVENT ID")
                CopyableRow("hex", note.id, colors.primary, context)
                CopyableRow("note1", note1, colors.primary, context)
                CopyableRow("nevent", nevent, colors.primary, context)
                CopyableRow("share link", shareLink, colors.primary, context)
            }

            HorizontalDivider(color = SecondaryText.copy(alpha = 0.2f))

            // RAW EVENT section.
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    SectionHeader("RAW EVENT")
                    Spacer(Modifier.weight(1f))
                    if (isFetching) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(16.dp),
                            strokeWidth = 2.dp,
                            color = colors.primary,
                        )
                    } else {
                        TextButton(
                            onClick = { copyToClipboard(context, "Event JSON", displayedJson) },
                            contentPadding = PaddingValues(horizontal = 4.dp, vertical = 0.dp),
                        ) {
                            Icon(NostrVaultIcons.Copy, contentDescription = null, modifier = Modifier.size(14.dp), tint = colors.primary)
                            Spacer(Modifier.width(4.dp))
                            Text("Copy", color = colors.primary, fontSize = 12.sp, fontWeight = FontWeight.Medium)
                        }
                    }
                }
                Surface(
                    color = WindowBackground.copy(alpha = 0.5f),
                    shape = RoundedCornerShape(8.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(
                        text = displayedJson,
                        color = PrimaryText.copy(alpha = 0.85f),
                        fontSize = 11.sp,
                        fontFamily = FontFamily.Monospace,
                        modifier = Modifier.padding(10.dp),
                    )
                }
            }

            HorizontalDivider(color = SecondaryText.copy(alpha = 0.2f))

            // BROADCAST section.
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                SectionHeader("BROADCAST")

                Surface(
                    color = WindowBackground.copy(alpha = 0.5f),
                    shape = RoundedCornerShape(8.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Column(
                        modifier = Modifier.padding(10.dp),
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Text(
                            text = "Broadcasting to ${blastrRelays.size} relay(s):",
                            color = SecondaryText,
                            fontSize = 12.sp,
                            fontFamily = FontFamily.Monospace,
                        )
                        blastrRelays.take(6).forEach { relay ->
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                Box(modifier = Modifier.size(12.dp), contentAlignment = Alignment.Center) {
                                    when {
                                        succeededRelays.contains(relay) -> Icon(
                                            NostrVaultIcons.Check,
                                            contentDescription = "Success",
                                            tint = SuccessGreen,
                                            modifier = Modifier.size(12.dp),
                                        )
                                        failedRelays.contains(relay) -> Icon(
                                            NostrVaultIcons.Dismiss,
                                            contentDescription = "Failed",
                                            tint = ErrorRed,
                                            modifier = Modifier.size(12.dp),
                                        )
                                        pendingRelays.contains(relay) -> CircularProgressIndicator(
                                            modifier = Modifier.size(10.dp),
                                            strokeWidth = 1.5.dp,
                                            color = colors.primary,
                                        )
                                        else -> Box(
                                            modifier = Modifier
                                                .size(6.dp)
                                                .clip(RoundedCornerShape(50))
                                                .background(colors.primary.copy(alpha = 0.5f)),
                                        )
                                    }
                                }
                                Text(
                                    text = relay,
                                    color = SecondaryText.copy(alpha = 0.8f),
                                    fontSize = 11.sp,
                                    fontFamily = FontFamily.Monospace,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                        }
                        if (blastrRelays.size > 6) {
                            Text(
                                text = "+ ${blastrRelays.size - 6} more",
                                color = SecondaryText.copy(alpha = 0.6f),
                                fontSize = 11.sp,
                                fontFamily = FontFamily.Monospace,
                            )
                        }
                    }
                }

                broadcastResult?.let { result ->
                    val ok = failedRelays.isEmpty()
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Icon(
                            if (ok) NostrVaultIcons.Check else NostrVaultIcons.Alert,
                            contentDescription = null,
                            tint = if (ok) SuccessGreen else ZapOrange,
                            modifier = Modifier.size(16.dp),
                        )
                        Text(
                            text = result,
                            color = if (ok) SuccessGreen else ZapOrange,
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Medium,
                            fontFamily = FontFamily.Monospace,
                        )
                    }
                }

                val enabled = fullEventJson != null && !isBroadcasting
                Button(
                    onClick = { broadcast() },
                    enabled = enabled,
                    shape = RoundedCornerShape(10.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = colors.primary,
                        contentColor = Color.White,
                        disabledContainerColor = SecondaryText.copy(alpha = 0.4f),
                        disabledContentColor = Color.White,
                    ),
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(48.dp),
                ) {
                    if (isBroadcasting) {
                        CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp, color = Color.White)
                    } else {
                        Icon(NostrVaultIcons.Relay, contentDescription = null, modifier = Modifier.size(18.dp))
                    }
                    Spacer(Modifier.width(8.dp))
                    Text(
                        text = if (isBroadcasting) "Broadcasting..." else "Re-Broadcast Event",
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 14.sp,
                    )
                }
            }
        }
    }
}

@Composable
private fun SectionHeader(text: String) {
    Text(
        text = text,
        color = SecondaryText,
        fontSize = 11.sp,
        fontWeight = FontWeight.SemiBold,
        fontFamily = FontFamily.Monospace,
        letterSpacing = 0.5.sp,
    )
}

@Composable
private fun CopyableRow(label: String, value: String, accent: Color, context: Context) {
    var copied by remember { mutableStateOf(false) }
    LaunchedEffect(copied) {
        if (copied) {
            kotlinx.coroutines.delay(2000)
            copied = false
        }
    }
    Surface(
        color = WindowBackground.copy(alpha = 0.5f),
        shape = RoundedCornerShape(8.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(10.dp),
        ) {
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Text(
                    text = label,
                    color = SecondaryText,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Medium,
                    fontFamily = FontFamily.Monospace,
                )
                Text(
                    text = middleTruncate(value),
                    color = PrimaryText,
                    fontSize = 11.sp,
                    fontFamily = FontFamily.Monospace,
                    maxLines = 1,
                )
            }
            IconButton(
                onClick = {
                    copyToClipboard(context, label, value)
                    copied = true
                },
                modifier = Modifier.size(32.dp),
            ) {
                Icon(
                    if (copied) NostrVaultIcons.Check else NostrVaultIcons.Copy,
                    contentDescription = "Copy $label",
                    tint = if (copied) SuccessGreen else accent,
                    modifier = Modifier.size(16.dp),
                )
            }
        }
    }
}

private fun copyToClipboard(context: Context, label: String, value: String) {
    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    clipboard.setPrimaryClip(ClipData.newPlainText(label, value))
}
