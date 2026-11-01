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
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.viewModelScope
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import com.nostrvault.ui.components.setSoundOnly
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
import com.nostrvault.ui.components.claimSound
import com.nostrvault.ui.screens.dm.DMAttachment
import com.nostrvault.ui.theme.*
import android.net.Uri
import com.nostrvault.ui.screens.live.LiveChat
import com.nostrvault.ui.screens.live.LiveChatMediaButton
import com.nostrvault.ui.screens.live.LiveFollowButton
import com.nostrvault.ui.screens.live.LiveFullScreen
import com.nostrvault.ui.screens.live.LiveMuteConfirm
import com.nostrvault.ui.screens.live.LiveShareButton
import com.nostrvault.ui.screens.live.LiveStreamLeave
import com.nostrvault.ui.screens.live.LiveStreamShare
import androidx.compose.foundation.clickable
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.material.icons.filled.Fullscreen
import com.nostrvault.ui.screens.live.LiveStreamViewModel
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject
import com.nostrvault.ui.components.ProseKeyboardOptions

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
    val followed by viewModel.followed.collectAsState()
    val blocked by viewModel.blocked.collectAsState()
    val uploading by viewModel.uploading.collectAsState()
    val saveGifsToBlossom by viewModel.saveGifsToBlossom.collectAsState()
    var fullScreen by rememberSaveable { mutableStateOf(false) }
    // Muting publishes the mute list, so it asks first.
    var muting by remember { mutableStateOf<String?>(null) }
    val focusManager = LocalFocusManager.current
    // Muted chatters drop out of the room as soon as they are muted.
    val shownMessages = remember(messages, blocked) { messages.filter { it.pubkey !in blocked } }

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
        // Minimized, the stream played sound only (MiniPlayerBar); the window
        // shows the picture, so the video track goes back on.
        p.setSoundOnly(false)
        if (!p.playWhenReady) {
            if (p.playbackState == Player.STATE_IDLE) p.prepare()
            p.play()
        }
    }

    // Another app took the sound (its own video, say): coming back to the app
    // carries on with the broadcast where it is now. Paused by the owner, the
    // stream stays paused.
    val lifecycleOwner = LocalLifecycleOwner.current
    // The mini player's stream plays on in the background: that is what
    // minimizing is for. Off screen it goes sound only (the smallest variant),
    // and the picture comes back with the screen.
    DisposableEffect(sharedPlayer, lifecycleOwner) {
        val p = sharedPlayer ?: return@DisposableEffect onDispose {}
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_STOP -> p.setSoundOnly(true)
                Lifecycle.Event.ON_START -> p.setSoundOnly(false)
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    // The mini player's own player does this itself (MusicPlayer.setAppInForeground).
    // This screen's own player stops off screen: a live stream left open
    // behind a locked phone downloaded 1.5–3 Mbps around the clock. Back on
    // screen it rejoins the broadcast where it is now.
    DisposableEffect(ownPlayer, lifecycleOwner) {
        val p = ownPlayer ?: return@DisposableEffect onDispose {}
        var pausedByOtherApp = false
        var pausedOffScreen = false
        val listener = object : Player.Listener {
            override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
                pausedByOtherApp = !playWhenReady &&
                    reason == Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_FOCUS_LOSS
            }
        }
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP && p.playWhenReady) {
                pausedOffScreen = true
                p.pause()
            } else if (event == Lifecycle.Event.ON_START && (pausedByOtherApp || pausedOffScreen)) {
                pausedByOtherApp = false
                pausedOffScreen = false
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

    // Somewhere else in the app (a profile, the composer): the stream carries on
    // in the mini player, the player closes, and the nav host opens the route.
    fun leaveFor(open: () -> Unit) {
        val s = stream ?: return
        LiveStreamLeave.minimize(s, hostName, chatProfiles[s.hostPubkey]?.pictureURL, alreadyMini = sharedPlayer != null)
        open()
        onBack()
    }
    // Only a real key leaves the player: a route is built from it.
    val openProfile: (String) -> Unit = { pk ->
        if (LiveStreamLeave.isPubkey(pk)) leaveFor { LiveStreamLeave.openProfile(pk) }
    }

    if (fullScreen && stream != null && player != null) {
        LiveFullScreen(
            player = player,
            messages = shownMessages,
            profiles = chatProfiles,
            onExit = { fullScreen = false },
            onOpenProfile = openProfile,
            onMute = { muting = it },
            onReport = { reportingMessage = it },
        )
        muting?.let { pk -> LiveMuteConfirm(chatProfiles[pk]?.bestName, onConfirm = { muting = null; viewModel.muteChatter(pk) }, onDismiss = { muting = null }) }
        reportingMessage?.let { entry ->
            UGCReportDialog(
                onReport = { reason, description ->
                    reportingMessage = null
                    viewModel.reportMessage(entry, reason, description)
                },
                onDismiss = { reportingMessage = null },
            )
        }
        return
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
                        LiveStreamLeave.minimize(
                            stream, hostName, chatProfiles[stream.hostPubkey]?.pictureURL, alreadyMini = sharedPlayer != null,
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
                // Sideways and edge to edge, the chat hidden or over the video.
                IconButton(
                    onClick = { focusManager.clearFocus(); fullScreen = true },
                    modifier = Modifier.align(Alignment.TopEnd).padding(6.dp),
                ) {
                    Box(
                        contentAlignment = Alignment.Center,
                        modifier = Modifier
                            .size(36.dp)
                            .background(Color.Black.copy(alpha = 0.45f), CircleShape),
                    ) {
                        Icon(
                            androidx.compose.material.icons.Icons.Filled.Fullscreen,
                            contentDescription = "Full screen",
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
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                text = buildString {
                                    append(hostName ?: stream.hostPubkey.take(8))
                                    stream.participants?.let { append(" · $it watching") }
                                },
                                color = SecondaryText,
                                fontSize = 13.sp,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier
                                    .weight(1f, fill = false)
                                    .clickable(onClickLabel = "Open the streamer's profile") { openProfile(stream.hostPubkey) },
                            )
                            Spacer(Modifier.width(8.dp))
                            LiveFollowButton(
                                following = stream.hostPubkey in followed,
                                onToggle = { viewModel.toggleFollow(stream.hostPubkey) },
                            )
                        }
                    }
                    LiveShareButton(
                        stream = stream,
                        hostName = hostName,
                        onShareAsNote = { leaveFor { LiveStreamLeave.compose(LiveStreamShare.noteText(stream, hostName)) } },
                        onOpenHost = { openProfile(stream.hostPubkey) },
                        onCopied = { viewModel.showStatus("Link copied") },
                    )
                    // The report and block affordances any surface showing
                    // third-party video needs. iOS: LiveStreamPlayerView header.
                    Box {
                        IconButton(onClick = { showHostMenu = true }) {
                            Icon(NostrVaultIcons.More, contentDescription = "Stream options", tint = colors.primary)
                        }
                        DropdownMenu(expanded = showHostMenu, onDismissRequest = { showHostMenu = false }) {
                            com.nostrvault.ui.components.NostrWebLinks.forStream(stream)?.let { link ->
                                DropdownMenuItem(
                                    text = { Text(link.label) },
                                    leadingIcon = { Icon(NostrVaultIcons.OpenExternal, contentDescription = null) },
                                    onClick = {
                                        showHostMenu = false
                                        com.nostrvault.ui.components.NostrWebLinks.open(context, link.url)
                                    },
                                )
                            }
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
                    // Hidden when ⚡️ is out of Appearance → Post buttons (iOS LiveStreamPlayerView).
                    if (LocalShowZapButton.current) Button(
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
                messages = shownMessages,
                profiles = chatProfiles,
                onReport = { reportingMessage = it },
                onOpenProfile = openProfile,
                onMute = { muting = it },
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
                // A photo, video or GIF, or something from your Vault, sent as its link.
                val addLink: (String) -> Unit = { link ->
                    val typed = chatInput.trim()
                    chatInput = if (typed.isEmpty()) link else "$typed $link"
                }
                LiveChatMediaButton(
                    uploading = uploading,
                    onBeforeOpen = { focusManager.clearFocus() },
                    onLink = addLink,
                    upload = { uri -> viewModel.uploadChatMedia(uri, addLink) },
                    uploadFile = { file, mime ->
                        viewModel.uploadChatMedia(Uri.fromFile(file), addLink, mimeType = mime, deleteAfter = file)
                    },
                    saveGifsToBlossom = saveGifsToBlossom,
                    onSaveGifsToBlossomChange = viewModel::setSaveGifsToBlossom,
                    onError = { viewModel.showStatus(it) },
                    loadVaultItems = viewModel::loadBlossomMedia,
                )
                OutlinedTextField(
                    value = chatInput,
                    onValueChange = { chatInput = it },
                    placeholder = { Text("Say something", color = TertiaryText) },
                    keyboardOptions = ProseKeyboardOptions,
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
        muting?.let { pk -> LiveMuteConfirm(chatProfiles[pk]?.bestName, onConfirm = { muting = null; viewModel.muteChatter(pk) }, onDismiss = { muting = null }) }
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

        if (showZapSheet) {
            // The shared zap sheet, starting on the Wallet default (iOS
            // LiveFeedViews CustomZapSheet(defaultAmount:)).
            CustomZapSheet(
                sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                defaultAmount = viewModel.defaultZapAmount(),
                onDismiss = { showZapSheet = false },
                onZap = { sats, comment ->
                    showZapSheet = false
                    viewModel.zap(stream, sats, comment)
                },
            )
        }
    }
}
