package com.nostrvault.ui.screens

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.viewModelScope
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import coil.compose.AsyncImage
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.LiveStream
import com.nostrvault.service.FeedService
import com.nostrvault.service.LiveChatService
import com.nostrvault.service.NostrService
import com.nostrvault.service.ZapSendService
import com.nostrvault.service.music.LiveRejoinListener
import com.nostrvault.service.music.MusicPlayer
import com.nostrvault.service.music.PlayerTrack
import com.nostrvault.service.music.rejoinLiveEdge
import com.nostrvault.ui.components.UGCReportDialog
import com.nostrvault.ui.components.claimSound
import com.nostrvault.ui.screens.dm.DMAttachment
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Player for one NIP-53 live stream.
 *
 * The stream is passed in rather than looked up by id: a kind-30311 event is
 * replaceable and short-lived, so the copy the grid was showing when the user
 * tapped is the one to play. Re-resolving could open a different broadcast, or
 * none.
 */
@OptIn(ExperimentalMaterial3Api::class)
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
@Composable
fun LiveStreamScreen(
    stream: LiveStream?,
    hostName: String?,
    onBack: () -> Unit,
    viewModel: LiveStreamViewModel = hiltViewModel(),
) {
    val colors = LocalNostrVaultColors.current
    val context = LocalContext.current
    val messages by viewModel.messages.collectAsState()
    val chatProfiles by viewModel.profiles.collectAsState()
    val status by viewModel.status.collectAsState()
    val sending by viewModel.sending.collectAsState()
    var chatInput by remember { mutableStateOf("") }
    var showZapSheet by remember { mutableStateOf(false) }
    var showHostMenu by remember { mutableStateOf(false) }
    var showReportStream by remember { mutableStateOf(false) }
    var showBlockConfirm by remember { mutableStateOf(false) }
    var reportingMessage by remember { mutableStateOf<LiveChatService.ChatEntry?>(null) }
    var showBlossomPicker by remember { mutableStateOf(false) }
    val focusManager = LocalFocusManager.current

    // Chat is joined for exactly as long as this screen is up.
    DisposableEffect(stream?.address) {
        stream?.let { viewModel.join(it) }
        onDispose { viewModel.leave() }
    }

    val player = remember(stream?.streamingUrl) {
        val url = stream?.streamingUrl ?: return@remember null
        ExoPlayer.Builder(context).build().apply {
            setMediaItem(MediaItem.fromUri(url))
            prepare()
            playWhenReady = true
            // Play after a pause rejoins the broadcast; left paused, the item
            // falls behind the live window and resuming it only fails.
            addListener(LiveRejoinListener(this))
            // The stream takes the sound: a playing song pauses.
            claimSound(true)
        }
    }
    // A player left running behind a closed screen keeps the socket and the
    // audio session; releasing on dispose is not optional.
    DisposableEffect(player) { onDispose { player?.release() } }

    // Another app took the sound (its own video, say): coming back to the app
    // carries on with the broadcast where it is now. Paused by the owner, the
    // stream stays paused.
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(player, lifecycleOwner) {
        val p = player ?: return@DisposableEffect onDispose {}
        var pausedByOtherApp = false
        val listener = object : Player.Listener {
            override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
                pausedByOtherApp = !playWhenReady &&
                    reason == Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_FOCUS_LOSS
            }
        }
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_START && pausedByOtherApp) {
                pausedByOtherApp = false
                p.rejoinLiveEdge()
                p.play()
            }
        }
        p.addListener(listener)
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
            p.removeListener(listener)
        }
    }

    Scaffold(
        containerColor = WindowBackground,
        topBar = {
            TopAppBar(
                title = { Text("Live", color = PrimaryText, fontSize = 17.sp) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(NostrVaultIcons.Back, contentDescription = "Back", tint = colors.primary)
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = WindowBackground),
            )
        },
    ) { padding ->
        if (stream == null || player == null) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier.fillMaxSize().padding(padding),
            ) {
                Text(
                    "That stream is no longer listed. Live events expire — go back and refresh.",
                    color = SecondaryText,
                    fontSize = 14.sp,
                )
            }
            return@Scaffold
        }

        Column(modifier = Modifier.padding(padding)) {
            Box {
                AndroidView(
                    factory = { ctx ->
                        PlayerView(ctx).apply {
                            this.player = player
                            useController = true
                        }
                    },
                    modifier = Modifier
                        .fillMaxWidth()
                        .aspectRatio(16f / 9f)
                        .background(Color.Black),
                )
                // Minimize: the stream's sound carries on in the mini player and
                // the notification while you browse; Watch in the full player
                // brings the video back. iOS: listenInBackground.
                IconButton(
                    onClick = {
                        MusicPlayer.playLive(
                            stream,
                            PlayerTrack(
                                id = "live:${stream.address}",
                                title = stream.title ?: "Live stream",
                                artist = hostName ?: ("npub…" + stream.hostPubkey.takeLast(6)),
                                artworkUrl = stream.imageUrl
                                    ?: stream.previewImageUrls.firstOrNull()
                                    ?: chatProfiles[stream.hostPubkey]?.pictureURL,
                                audioUrl = stream.streamingUrl ?: return@IconButton,
                                durationSec = null,
                                isLive = true,
                                hostPubkey = stream.hostPubkey,
                            ),
                        )
                        onBack()
                    },
                    modifier = Modifier.padding(6.dp),
                ) {
                    Box(
                        contentAlignment = Alignment.Center,
                        modifier = Modifier
                            .size(36.dp)
                            .background(Color.Black.copy(alpha = 0.45f), CircleShape),
                    ) {
                        Icon(
                            NostrVaultIcons.ChevronDown,
                            contentDescription = "Minimize, keep listening while you browse",
                            tint = Color.White,
                        )
                    }
                }
            }
            Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = stream.title ?: "Untitled stream",
                            color = PrimaryText,
                            fontSize = 18.sp,
                            fontWeight = FontWeight.Bold,
                            lineHeight = 24.sp,
                            maxLines = 2,
                        )
                        Spacer(Modifier.height(4.dp))
                        Text(
                            text = buildString {
                                append(hostName ?: stream.hostPubkey.take(8))
                                stream.participants?.let { append(" · $it watching") }
                            },
                            color = SecondaryText,
                            fontSize = 13.sp,
                        )
                    }
                    // The report and block affordances any surface showing
                    // third-party video needs. iOS: LiveStreamPlayerView header.
                    Box {
                        IconButton(onClick = { showHostMenu = true }) {
                            Icon(NostrVaultIcons.More, contentDescription = "Stream options", tint = colors.primary)
                        }
                        DropdownMenu(expanded = showHostMenu, onDismissRequest = { showHostMenu = false }) {
                            DropdownMenuItem(
                                text = { Text("Report stream") },
                                leadingIcon = { Icon(NostrVaultIcons.Alert, contentDescription = null) },
                                onClick = {
                                    showHostMenu = false
                                    showReportStream = true
                                },
                            )
                            DropdownMenuItem(
                                text = { Text("Block host", color = ErrorRed) },
                                leadingIcon = { Icon(NostrVaultIcons.Blocked, contentDescription = null, tint = ErrorRed) },
                                onClick = {
                                    showHostMenu = false
                                    showBlockConfirm = true
                                },
                            )
                        }
                    }
                    Button(
                        onClick = { showZapSheet = true },
                        colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
                    ) { Text("Zap", color = PrimaryText, fontWeight = FontWeight.SemiBold) }
                }
                status?.let {
                    Spacer(Modifier.height(8.dp))
                    Text(it, color = colors.primary, fontSize = 12.sp)
                }
            }

            HorizontalDivider(color = colors.primary.copy(alpha = 0.12f))

            LiveChat(
                messages = messages,
                profiles = chatProfiles,
                onReport = { reportingMessage = it },
                // Touching the chat, to tap or drag it, puts the keyboard away.
                modifier = Modifier
                    .weight(1f)
                    .pointerInput(Unit) {
                        awaitEachGesture {
                            awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
                            focusManager.clearFocus()
                        }
                    },
            )

            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .navigationBarsPadding()
                    .imePadding()
                    // LiveStreamHost draws this above the floating tab bar, so
                    // no room is kept for it.
                    .padding(start = 12.dp, end = 12.dp, top = 8.dp, bottom = 8.dp),
            ) {
                // Media from your relay's Blossom store, sent as its link.
                IconButton(
                    onClick = {
                        focusManager.clearFocus()
                        showBlossomPicker = true
                    },
                ) {
                    Icon(
                        imageVector = NostrVaultIcons.Media,
                        contentDescription = "Add media from your relay",
                        tint = colors.primary,
                    )
                }
                OutlinedTextField(
                    value = chatInput,
                    onValueChange = { chatInput = it },
                    placeholder = { Text("Say something", color = TertiaryText) },
                    singleLine = true,
                    modifier = Modifier.weight(1f),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedTextColor = PrimaryText,
                        unfocusedTextColor = PrimaryText,
                        cursorColor = colors.primary,
                        focusedBorderColor = colors.primary,
                    ),
                )
                Spacer(Modifier.width(8.dp))
                Button(
                    onClick = {
                        viewModel.send(stream, chatInput)
                        chatInput = ""
                    },
                    enabled = chatInput.isNotBlank() && !sending,
                    colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
                ) { Text("Send", color = PrimaryText) }
            }
        }

        // Reporting also blocks, as the report dialog does everywhere else in
        // the app — so the stream closes.
        if (showReportStream) {
            UGCReportDialog(
                onReport = { reason, description ->
                    showReportStream = false
                    viewModel.reportHost(stream, reason, description)
                    onBack()
                },
                onDismiss = { showReportStream = false },
            )
        }
        reportingMessage?.let { entry ->
            UGCReportDialog(
                onReport = { reason, description ->
                    reportingMessage = null
                    viewModel.reportMessage(entry, reason, description)
                },
                onDismiss = { reportingMessage = null },
            )
        }
        if (showBlockConfirm) {
            AlertDialog(
                onDismissRequest = { showBlockConfirm = false },
                title = { Text("Block this host?") },
                text = { Text("Their streams and posts stop appearing for you.") },
                confirmButton = {
                    TextButton(onClick = {
                        showBlockConfirm = false
                        viewModel.blockHost(stream)
                        onBack()
                    }) { Text("Block", color = ErrorRed) }
                },
                dismissButton = {
                    TextButton(onClick = { showBlockConfirm = false }) { Text("Cancel") }
                },
            )
        }

        if (showBlossomPicker) {
            BlossomMediaPickerSheet(
                onDismiss = { showBlossomPicker = false },
                onSelect = { item ->
                    // The link goes after anything already typed, ready to send.
                    val typed = chatInput.trim()
                    val link = blossomShareLink(item)
                    chatInput = if (typed.isEmpty()) link else "$typed $link"
                    showBlossomPicker = false
                },
                loadItems = viewModel::loadBlossomMedia,
            )
        }

        if (showZapSheet) {
            ZapAmountSheet(
                onPick = { sats ->
                    showZapSheet = false
                    viewModel.zap(stream, sats)
                },
                onDismiss = { showZapSheet = false },
            )
        }
    }
}
/**
 * The room. Chat lines and zaps share one list because that is how a live
 * audience experiences them — a 5,000 sat zap is a louder message, not a
 * separate feature.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun LiveChat(
    messages: List<LiveChatService.ChatEntry>,
    profiles: Map<String, FeedProfile>,
    /** Long-press a line to report it. */
    onReport: (LiveChatService.ChatEntry) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalNostrVaultColors.current
    val listState = rememberLazyListState()

    // Follow the conversation, the way every chat does.
    LaunchedEffect(messages.size) {
        if (messages.isNotEmpty()) listState.animateScrollToItem(messages.lastIndex)
    }

    if (messages.isEmpty()) {
        Box(contentAlignment = Alignment.Center, modifier = modifier.fillMaxWidth()) {
            Text("No chat yet", color = TertiaryText, fontSize = 13.sp)
        }
        return
    }

    LazyColumn(state = listState, modifier = modifier.fillMaxWidth()) {
        items(messages, key = { it.id }) { entry ->
            val name = profiles[entry.pubkey]?.bestName ?: entry.pubkey.take(8)
            var showMenu by remember { mutableStateOf(false) }
            Box {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .combinedClickable(
                            onClick = {},
                            onLongClick = { showMenu = true },
                            onLongClickLabel = "Message options",
                        )
                        .padding(horizontal = 16.dp, vertical = 5.dp),
                ) {
                    if (entry.zapSats != null) {
                        Text(
                            // A zap whose amount the receipt did not carry still
                            // happened — show the bolt, not a zero.
                            text = if (entry.zapSats > 0) "⚡ ${entry.zapSats}" else "⚡",
                            color = colors.primary,
                            fontSize = 13.sp,
                            fontWeight = FontWeight.Bold,
                        )
                        Spacer(Modifier.width(6.dp))
                    }
                    // Image links come out of the text and show as pictures
                    // under it, whoever sent them.
                    val parts = remember(entry.content) { DMAttachment.split(entry.content) }
                    Column {
                        Text(
                            text = buildString {
                                append(name)
                                if (parts.text.isNotEmpty()) {
                                    append("  ")
                                    append(parts.text)
                                }
                            },
                            color = if (entry.zapSats != null) colors.primary else PrimaryText,
                            fontSize = 13.sp,
                            lineHeight = 18.sp,
                        )
                        parts.images.forEach { url ->
                            AsyncImage(
                                model = url,
                                contentDescription = null,
                                contentScale = ContentScale.Crop,
                                modifier = Modifier
                                    .padding(top = 6.dp)
                                    .size(180.dp)
                                    .clip(RoundedCornerShape(10.dp)),
                            )
                        }
                    }
                }
                DropdownMenu(expanded = showMenu, onDismissRequest = { showMenu = false }) {
                    DropdownMenuItem(
                        text = { Text("Report message") },
                        leadingIcon = { Icon(NostrVaultIcons.Alert, contentDescription = null) },
                        onClick = {
                            showMenu = false
                            onReport(entry)
                        },
                    )
                }
            }
        }
    }
}

/** Fixed amounts, because typing a number mid-stream is not what anyone wants. */
@Composable
private fun ZapAmountSheet(onPick: (Int) -> Unit, onDismiss: () -> Unit) {
    val colors = LocalNostrVaultColors.current
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = WindowBackground,
        title = { Text("Zap the host", color = PrimaryText) },
        text = {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf(21, 100, 500, 2100).forEach { sats ->
                    Button(
                        onClick = { onPick(sats) },
                        colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
                    ) { Text("$sats", color = PrimaryText, fontSize = 13.sp) }
                }
            }
        },
        confirmButton = {},
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel", color = SecondaryText) }
        },
    )
}


/**
 * Chat and zaps for the stream on screen.
 *
 * Joining connects to the streaming relays for as long as this screen is up;
 * leaving disconnects. A live room's traffic is not something to keep a socket
 * open for behind a screen nobody is watching.
 */
@HiltViewModel
class LiveStreamViewModel @Inject constructor(
    private val liveChatService: LiveChatService,
    private val zapSendService: ZapSendService,
    private val nostrService: NostrService,
    private val feedService: FeedService,
    private val blossomPickerMedia: BlossomPickerMedia,
) : ViewModel() {

    val messages: StateFlow<List<LiveChatService.ChatEntry>> = liveChatService.messages

    /** Media for the chat's Blossom picker, the same list the composer shows. */
    suspend fun loadBlossomMedia(): List<BlossomMediaItem> = blossomPickerMedia.load()
    val profiles: StateFlow<Map<String, FeedProfile>> = nostrService.profiles

    private val _status = MutableStateFlow<String?>(null)
    val status: StateFlow<String?> = _status.asStateFlow()

    private val _sending = MutableStateFlow(false)
    val sending: StateFlow<Boolean> = _sending.asStateFlow()

    fun join(stream: LiveStream) {
        // One view model serves every stream opened (LiveStreamHost sits
        // outside the nav graph), so the last stream's "Zapped" must not carry over.
        _status.value = null
        liveChatService.join(stream)
    }

    fun leave() = liveChatService.leave()

    fun send(stream: LiveStream, text: String) {
        viewModelScope.launch {
            _sending.value = true
            val ok = liveChatService.send(stream, text)
            _sending.value = false
            if (!ok) _status.value = "Could not send — no relay accepted it"
        }
    }

    /**
     * Zap the stream's host. The stream address goes on the zap request so the
     * receipt lands in this room's chat rather than only in the host's notes.
     */
    fun zap(stream: LiveStream, sats: Int) {
        viewModelScope.launch {
            _status.value = "Zapping $sats sats…"
            val result = zapSendService.zapNote(
                noteId = "",
                notePubkey = stream.hostPubkey,
                amountSats = sats,
                message = "Zap from Nostr Vault",
                addressTag = stream.address,
            )
            _status.value = result.fold(
                onSuccess = { "Zapped $sats sats" },
                onFailure = { it.message ?: "Zap failed" },
            )
        }
    }

    fun clearStatus() { _status.value = null }

    /**
     * NIP-56 report of the stream's host (the stream event has no id to hand),
     * then a block, as reporting does everywhere else in the app.
     */
    fun reportHost(stream: LiveStream, reason: String, description: String) {
        viewModelScope.launch {
            nostrService.reportUser(stream.hostPubkey, reason, description.ifBlank { null })
            feedService.blockUser(stream.hostPubkey)
        }
    }

    fun blockHost(stream: LiveStream) {
        viewModelScope.launch { feedService.blockUser(stream.hostPubkey) }
    }

    /**
     * Reports the event that carries the text — the receipt, for a zap line,
     * which is attributed to the payer — and blocks its author.
     */
    fun reportMessage(entry: LiveChatService.ChatEntry, reason: String, description: String) {
        viewModelScope.launch {
            nostrService.reportEvent(entry.id, entry.pubkey, reason, description.ifBlank { null })
            feedService.blockUser(entry.pubkey)
        }
    }
}
