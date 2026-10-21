package com.nostrvault.ui.screens

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.ui.components.CustomZapSheet
import com.nostrvault.ui.components.LocalShowZapButton
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
import androidx.compose.ui.text.style.TextOverflow
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
import com.nostrvault.service.LiveFeedService
import com.nostrvault.service.NostrService
import com.nostrvault.service.ZapSendService
import com.nostrvault.service.music.LiveRejoinListener
import com.nostrvault.service.music.MusicPlayer
import com.nostrvault.service.music.PlayerTrack
import com.nostrvault.service.music.rejoinLiveEdge
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.components.UGCReportDialog
import com.nostrvault.ui.components.liveHostFallback
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
    val zapFailure by viewModel.zapFailure.collectAsState()
    val sending by viewModel.sending.collectAsState()
    var chatInput by remember { mutableStateOf("") }
    var showZapSheet by remember { mutableStateOf(false) }
    var showNoLightningAddress by remember { mutableStateOf(false) }
    var showReportStream by remember { mutableStateOf(false) }
    var showBlockConfirm by remember { mutableStateOf(false) }
    var reportingMessage by remember { mutableStateOf<LiveChatService.ChatEntry?>(null) }
    var showBlossomPicker by remember { mutableStateOf(false) }
    val focusManager = LocalFocusManager.current
    val displayHost = hostName ?: stream?.let { liveHostFallback(it.hostPubkey) }.orEmpty()

    // Chat is joined for exactly as long as this screen is up.
    DisposableEffect(stream?.address) {
        stream?.let { viewModel.join(it) }
        onDispose { viewModel.leave() }
    }

    // The mini player's own player, when this is the stream it has
    // minimized: read once, as the screen opens. The screen shows that
    // player's video instead of opening the stream again, so popping out of
    // the mini player and going back never stops the sound. iOS #301.
    val sharedPlayer = remember(stream?.address) { stream?.let { MusicPlayer.livePlayer(it.address) } }
    val ownPlayer = remember(stream?.streamingUrl, sharedPlayer) {
        if (sharedPlayer != null) return@remember null
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
    // A shared player is the mini player's, which carries on.
    DisposableEffect(ownPlayer) { onDispose { ownPlayer?.release() } }
    val player: Player? = sharedPlayer ?: ownPlayer
    // Popped out of a paused mini player, the stream plays; Play rejoins the
    // broadcast where it is now (LiveRejoinListener in the service).
    LaunchedEffect(sharedPlayer) {
        val p = sharedPlayer ?: return@LaunchedEffect
        if (!p.playWhenReady) {
            if (p.playbackState == Player.STATE_IDLE) p.prepare()
            p.play()
        }
    }

    // Another app took the sound (its own video, say): coming back to the app
    // carries on with the broadcast where it is now. Paused by the owner, the
    // stream stays paused.
    val lifecycleOwner = LocalLifecycleOwner.current
    // The mini player's own player does this itself (MusicPlayer.setAppInForeground).
    DisposableEffect(ownPlayer, lifecycleOwner) {
        val p = ownPlayer ?: return@DisposableEffect onDispose {}
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
                    // Let go of the surface, so a shared player carries on
                    // as sound only in the mini player.
                    onRelease = { it.player = null },
                    modifier = Modifier
                        .fillMaxWidth()
                        .aspectRatio(16f / 9f)
                        .background(Color.Black),
                )
                // Minimize: the stream's sound carries on in the mini player and
                // the notification while you browse; tapping the mini player
                // brings the video back. iOS: listenInBackground.
                IconButton(
                    onClick = {
                        // Already the mini player's stream: it plays on as it is.
                        if (sharedPlayer == null) MusicPlayer.playLive(
                            stream,
                            PlayerTrack(
                                id = "live:${stream.address}",
                                title = stream.title ?: "Live stream",
                                artist = displayHost,
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
            LiveStreamHeader(
                stream = stream,
                hostName = displayHost,
                hostPictureUrl = chatProfiles[stream.hostPubkey]?.pictureURL,
                onReport = { showReportStream = true },
                onBlock = { showBlockConfirm = true },
            )

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

            LiveStreamComposer(
                text = chatInput,
                onTextChange = { chatInput = it },
                sending = sending,
                showZap = LocalShowZapButton.current,
                onMedia = {
                    focusManager.clearFocus()
                    showBlossomPicker = true
                },
                onZap = { showZapSheet = true },
                onSend = {
                    val text = chatInput
                    if (text.isNotBlank()) {
                        chatInput = ""
                        // A send no relay took puts the text back. iOS sendMessage().
                        viewModel.send(stream, text, onFailed = { chatInput = text })
                    }
                },
                modifier = Modifier
                    .navigationBarsPadding()
                    .imePadding()
                    // LiveStreamHost draws this above the floating tab bar, so
                    // no room is kept for it.
                    .padding(start = 12.dp, end = 12.dp, top = 8.dp, bottom = 8.dp),
            )
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
            // The shared zap sheet, starting on the Wallet default (iOS
            // LiveFeedViews CustomZapSheet(defaultAmount:)).
            CustomZapSheet(
                sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                defaultAmount = viewModel.defaultZapAmount(),
                onDismiss = { showZapSheet = false },
                onZap = { sats ->
                    showZapSheet = false
                    // The typed text is the zap's comment, and goes with it.
                    // iOS LiveStreamPlayerView.sendZap.
                    if (!viewModel.hasLightningAddress(stream.hostPubkey)) {
                        showNoLightningAddress = true
                    } else {
                        val comment = chatInput.trim()
                        chatInput = ""
                        viewModel.zap(stream, sats, comment)
                    }
                },
            )
        }

        // iOS: an alert when there is nowhere to pay or the zap fails; a zap
        // that goes through shows up in the chat, so success says nothing.
        if (showNoLightningAddress) {
            AlertDialog(
                onDismissRequest = { showNoLightningAddress = false },
                title = { Text("No Lightning address") },
                text = { Text("$displayHost has not published one, so there is nowhere to send sats.") },
                confirmButton = {
                    TextButton(onClick = { showNoLightningAddress = false }) { Text("OK") }
                },
            )
        }
        zapFailure?.let { message ->
            AlertDialog(
                onDismissRequest = viewModel::clearZapFailure,
                title = { Text("Zap failed") },
                text = { Text(message) },
                confirmButton = {
                    TextButton(onClick = viewModel::clearZapFailure) { Text("OK") }
                },
            )
        }
    }
}
