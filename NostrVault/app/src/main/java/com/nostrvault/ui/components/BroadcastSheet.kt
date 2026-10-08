package com.nostrvault.ui.components

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedNote
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.EventInspector
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService
import com.nostrvault.service.RelayPresence
import com.nostrvault.service.SignatureCheck
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.delay
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.add
import kotlinx.serialization.json.addJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import java.text.DateFormat

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

/** Common kind names; anything else shows its number only. */
private fun kindName(kind: Int): String = when (kind) {
    0 -> "Profile"
    1 -> "Note"
    3 -> "Contacts"
    4 -> "Encrypted DM"
    5 -> "Event Deletion"
    6 -> "Repost"
    7 -> "Reaction"
    16 -> "Generic Repost"
    20 -> "Picture"
    21, 22 -> "Video"
    1063 -> "File Metadata"
    1111 -> "Comment"
    1984 -> "Reporting"
    9734 -> "Zap Request"
    9735 -> "Zap"
    10002 -> "Relay List"
    30023 -> "Long-form Post"
    else -> "Event"
}

private data class BroadcastResult(val ok: Boolean, val message: String)

/**
 * Event Info (port of iOS EventBroadcastSheet): who posted an event and when,
 * whether its signature checks out, which relays have it, and what you can do
 * with it (copy, share, re-broadcast to the relays you pick). The lookup and
 * the signature check live in [EventInspector]; this only draws them.
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
    /** Opens a profile from the Trust Path map. Null hides its profile buttons. */
    onProfileClick: ((String) -> Unit)? = null,
) {
    val context = LocalContext.current
    val colors = LocalNostrVaultColors.current
    // Cancelled when the sheet leaves, which drops every relay socket.
    val scope = rememberCoroutineScope()

    val note1 = remember(note.id) { HavenBridge.hexToNote1(note.id) ?: note.id }
    val nevent = remember(note.id) { HavenBridge.encodeNevent(note.id, note.pubkey, note.kind) ?: note1 }
    val shareLink = remember(nevent) { threadLink(nevent) }
    val authorNpub = remember(note.pubkey) { HavenBridge.encodeNpub(note.pubkey) ?: note.pubkey }

    val inspector = remember(note.id) {
        EventInspector(
            eventId = note.id,
            config = configStore.config.value,
            scope = scope,
            cachedEventJson = feedService.getCachedRawEvent(note.id),
        )
    }
    val event by inspector.event.collectAsState()
    val isFetching by inspector.isFetching.collectAsState()
    val signature by inspector.signature.collectAsState()
    val relays by inspector.relays.collectAsState()
    val presence by inspector.presence.collectAsState()
    val profiles by nostrService.profiles.collectAsState()

    LaunchedEffect(note.id) {
        inspector.start()
        nostrService.fetchMissingProfiles(listOfNotNull(note.pubkey, note.repostedBy))
    }

    val displayedJson = remember(event) { formatEventJson(event ?: minimalEventJson(note)) }

    // Relays ticked to receive the next re-broadcast; starts on the blastr relays.
    var selected by remember(note.id) { mutableStateOf(inspector.defaultBroadcastRelays.toSet()) }
    var pending by remember { mutableStateOf(emptySet<String>()) }
    var results by remember { mutableStateOf(emptyMap<String, BroadcastResult>()) }
    var showRaw by remember { mutableStateOf(false) }
    val isBroadcasting = pending.isNotEmpty()

    fun broadcast() {
        val targets = relays.filter { it in selected } + (selected - relays.toSet()).sorted()
        if (targets.isEmpty()) return
        pending = targets.toSet()
        results = results - targets.toSet()
        inspector.broadcast(targets) { relay, ok, message ->
            pending = pending - relay
            results = results + (relay to BroadcastResult(ok, message))
        }
    }

    fun displayName(pubkey: String) = profiles[pubkey]?.bestName ?: "npub…${pubkey.takeLast(6)}"

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
            verticalArrangement = Arrangement.spacedBy(24.dp),
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

            // ── Summary ──────────────────────────────────────────
            val profile = profiles[note.pubkey]
            Card {
                Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        AvatarImage(url = profile?.pictureURL, pubkey = note.pubkey, size = 44.dp, displayName = profile?.bestName)
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(displayName(note.pubkey), color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text(
                                profile?.nip05?.takeIf { it.isNotBlank() } ?: middleTruncate(authorNpub),
                                color = SecondaryText, fontSize = 11.sp, fontFamily = FontFamily.Monospace, maxLines = 1,
                            )
                        }
                    }
                    HorizontalDivider(color = SecondaryText.copy(alpha = 0.2f))
                    FactRow("Kind") { FactText("${kindName(note.kind)} · ${note.kind}") }
                    FactRow("Posted") {
                        FactText(remember(note.createdAt) { DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(note.createdAt) })
                    }
                    note.repostedBy?.let { reposter -> FactRow("Reposted by") { FactText(displayName(reposter)) } }
                    FactRow("Signature") {
                        when (signature) {
                            SignatureCheck.VALID -> StatusLabel(NostrVaultIcons.Verified, "Valid", SuccessGreen)
                            SignatureCheck.INVALID -> StatusLabel(NostrVaultIcons.Dismiss, "Invalid", ErrorRed)
                            SignatureCheck.UNKNOWN -> if (isFetching) {
                                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                    SmallSpinner(SecondaryText)
                                    FactText("Checking", SecondaryText)
                                }
                            } else {
                                StatusLabel(NostrVaultIcons.Info, "Couldn't check", SecondaryText)
                            }
                        }
                    }
                }
            }

            // ── Trust Path ───────────────────────────────────────
            TrustPathCard(author = note.pubkey, onProfileClick = onProfileClick)

            // ── Actions ──────────────────────────────────────────
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                ActionTile("Copy link", NostrVaultIcons.LinkIcon, copies = true, Modifier.weight(1f)) {
                    copyToClipboard(context, "Share link", shareLink)
                }
                ActionTile("Share", NostrVaultIcons.Share, copies = false, Modifier.weight(1f)) {
                    val send = Intent(Intent.ACTION_SEND).apply {
                        type = "text/plain"
                        putExtra(Intent.EXTRA_TEXT, shareLink)
                    }
                    context.startActivity(Intent.createChooser(send, null))
                }
                ActionTile("Copy npub", NostrVaultIcons.AccountCircle, copies = true, Modifier.weight(1f)) {
                    copyToClipboard(context, "npub", authorNpub)
                }
                ActionTile("Copy JSON", NostrVaultIcons.Document, copies = true, Modifier.weight(1f), enabled = event != null) {
                    copyToClipboard(context, "Event JSON", displayedJson)
                }
            }

            // ── Relays ───────────────────────────────────────────
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                val foundCount = relays.count { presence[it] == RelayPresence.Found }
                val missing = relays.filter { presence[it] == RelayPresence.NotFound }
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    SectionHeader("RELAYS")
                    Spacer(Modifier.weight(1f))
                    if (isFetching) SmallSpinner(SecondaryText)
                    Text("On $foundCount of ${relays.size}", color = SecondaryText, fontSize = 11.sp, fontFamily = FontFamily.Monospace)
                }
                Card {
                    Column {
                        relays.forEachIndexed { index, relay ->
                            if (index > 0) HorizontalDivider(color = SecondaryText.copy(alpha = 0.15f), modifier = Modifier.padding(start = 40.dp))
                            RelayRow(
                                label = inspector.label(relay),
                                presence = presence[relay] ?: RelayPresence.Checking,
                                isPending = relay in pending,
                                result = results[relay],
                                isSelected = relay in selected,
                                enabled = !isBroadcasting,
                                accent = colors.primary,
                                onToggle = { selected = if (relay in selected) selected - relay else selected + relay },
                            )
                        }
                    }
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Tick the relays to send to.", color = SecondaryText, fontSize = 11.sp, modifier = Modifier.weight(1f))
                    if (missing.isNotEmpty()) {
                        TextButton(onClick = { selected = selected + missing }, enabled = !isBroadcasting) {
                            Text("Select missing (${missing.size})", color = colors.primary, fontSize = 12.sp, fontWeight = FontWeight.Medium)
                        }
                    }
                }

                val count = selected.size
                val enabled = !isBroadcasting && event != null && count > 0
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
                    modifier = Modifier.fillMaxWidth().height(48.dp),
                ) {
                    if (isBroadcasting) SmallSpinner(Color.White) else Icon(NostrVaultIcons.Relay, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(
                        text = when {
                            isBroadcasting -> "Sending…"
                            event == null -> if (isFetching) "Finding the signed event…" else "No signed copy to send"
                            count == 0 -> "Pick a relay"
                            count == 1 -> "Broadcast to 1 relay"
                            else -> "Broadcast to $count relays"
                        },
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 14.sp,
                    )
                }
            }

            // ── Identifiers + raw event ──────────────────────────
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("IDENTIFIERS")
                CopyableRow("hex", note.id, colors.primary, context)
                CopyableRow("note1", note1, colors.primary, context)
                CopyableRow("nevent", nevent, colors.primary, context)
                CopyableRow("share link", shareLink, colors.primary, context)

                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable(role = Role.Button, onClickLabel = if (showRaw) "Hide raw event" else "Show raw event") { showRaw = !showRaw }
                        .padding(top = 8.dp, bottom = 4.dp),
                ) {
                    SectionHeader("RAW EVENT")
                    Spacer(Modifier.weight(1f))
                    Icon(
                        NostrVaultIcons.ChevronDown,
                        contentDescription = null,
                        tint = SecondaryText,
                        modifier = Modifier.size(16.dp).rotate(if (showRaw) 0f else -90f),
                    )
                }
                AnimatedVisibility(visible = showRaw) {
                    Surface(color = WindowBackground.copy(alpha = 0.5f), shape = RoundedCornerShape(8.dp), modifier = Modifier.fillMaxWidth()) {
                        Text(
                            text = displayedJson,
                            color = PrimaryText.copy(alpha = 0.85f),
                            fontSize = 11.sp,
                            fontFamily = FontFamily.Monospace,
                            modifier = Modifier.padding(10.dp),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun Card(content: @Composable () -> Unit) {
    Surface(
        color = WindowBackground.copy(alpha = 0.5f),
        shape = RoundedCornerShape(12.dp),
        modifier = Modifier.fillMaxWidth(),
        content = content,
    )
}

@Composable
private fun FactRow(label: String, value: @Composable () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(label, color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.Medium)
        Spacer(Modifier.weight(1f).widthIn(min = 12.dp))
        value()
    }
}

@Composable
private fun FactText(text: String, color: Color = PrimaryText) {
    Text(text, color = color, fontSize = 12.sp, fontFamily = FontFamily.Monospace, maxLines = 1, overflow = TextOverflow.Ellipsis)
}

@Composable
private fun StatusLabel(icon: ImageVector, text: String, color: Color) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(14.dp))
        FactText(text, color)
    }
}

@Composable
private fun SmallSpinner(color: Color) {
    CircularProgressIndicator(modifier = Modifier.size(14.dp), strokeWidth = 1.5.dp, color = color)
}

@Composable
private fun ActionTile(
    title: String,
    icon: ImageVector,
    copies: Boolean,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    var copied by remember { mutableStateOf(false) }
    LaunchedEffect(copied) {
        if (copied) { delay(1500); copied = false }
    }
    val accent = LocalNostrVaultColors.current.primary
    Surface(
        color = WindowBackground.copy(alpha = 0.5f),
        shape = RoundedCornerShape(10.dp),
        modifier = modifier
            .clip(RoundedCornerShape(10.dp))
            .clickable(enabled = enabled, role = Role.Button, onClickLabel = title) {
                onClick()
                if (copies) copied = true
            },
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier.padding(vertical = 12.dp).alpha(if (enabled) 1f else 0.45f),
        ) {
            Icon(
                if (copied) NostrVaultIcons.Check else icon,
                contentDescription = null,
                tint = if (copied) SuccessGreen else accent,
                modifier = Modifier.size(20.dp),
            )
            Text(if (copied) "Copied" else title, color = PrimaryText, fontSize = 11.sp, fontWeight = FontWeight.Medium, maxLines = 1)
        }
    }
}

@Composable
private fun RelayRow(
    label: String,
    presence: RelayPresence,
    isPending: Boolean,
    result: BroadcastResult?,
    isSelected: Boolean,
    enabled: Boolean,
    accent: Color,
    onToggle: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.padding(start = 12.dp, end = 2.dp, top = 2.dp, bottom = 2.dp),
    ) {
        Box(Modifier.size(16.dp), contentAlignment = Alignment.Center) {
            when {
                isPending || presence == RelayPresence.Checking -> SmallSpinner(SecondaryText)
                presence == RelayPresence.Found -> Icon(NostrVaultIcons.Check, contentDescription = "Has it", tint = SuccessGreen, modifier = Modifier.size(16.dp))
                presence == RelayPresence.NotFound -> Box(
                    Modifier.size(14.dp).border(BorderStroke(1.5.dp, SecondaryText.copy(alpha = 0.7f)), CircleShape),
                )
                else -> Icon(NostrVaultIcons.Alert, contentDescription = "Couldn't check", tint = ZapOrange, modifier = Modifier.size(16.dp))
            }
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(label, color = PrimaryText, fontSize = 13.sp, fontFamily = FontFamily.Monospace, maxLines = 1, overflow = TextOverflow.Ellipsis)
            // The last broadcast's answer wins over the lookup: it is newer.
            val (detail, color) = when {
                isPending -> "Sending…" to SecondaryText
                result != null && result.ok -> "Sent" to SuccessGreen
                result != null -> "Rejected: ${result.message.ifEmpty { "failed" }}" to ErrorRed
                presence == RelayPresence.Checking -> "Checking…" to SecondaryText
                presence == RelayPresence.Found -> "Has it" to SecondaryText
                presence == RelayPresence.NotFound -> "Doesn't have it" to SecondaryText
                presence is RelayPresence.Failed -> "Couldn't check: ${presence.reason}" to ZapOrange
                else -> "" to SecondaryText
            }
            Text(detail, color = color, fontSize = 11.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        Checkbox(
            checked = isSelected,
            onCheckedChange = { onToggle() },
            enabled = enabled,
            colors = CheckboxDefaults.colors(checkedColor = accent),
        )
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
