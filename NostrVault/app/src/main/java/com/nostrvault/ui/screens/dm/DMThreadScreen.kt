package com.nostrvault.ui.screens.dm

import com.nostrvault.util.RelativeTime
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.foundation.text.input.clearText
import androidx.compose.foundation.text.input.setTextAndPlaceCursorAtEnd
import androidx.compose.foundation.text.selection.LocalTextSelectionColors
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.text.selection.TextSelectionColors
import android.content.Context
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import coil.compose.AsyncImage
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.service.BlossomService
import com.nostrvault.service.DMMessage
import com.nostrvault.service.DMService
import com.nostrvault.service.MediaPrivacy
import com.nostrvault.service.NostrService
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.components.FullScreenMediaRouter
import com.nostrvault.ui.components.MediaSourceKey
import com.nostrvault.ui.components.MediaZoomSources
import com.nostrvault.ui.components.NostrMentions
import com.nostrvault.ui.components.RetryableAsyncImage
import com.nostrvault.ui.components.mediaZoomSource
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.*
import javax.inject.Inject

/**
 * Individual DM conversation thread.
 * Port of DMThreadView.swift.
 */

@HiltViewModel
class DMThreadViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    @ApplicationContext private val context: Context,
    private val dmService: DMService,
    private val nostrService: NostrService,
    private val configStore: ConfigStore,
    private val blossomService: BlossomService,
) : ViewModel() {

    val counterpartyPubkey: String = savedStateHandle["pubkey"] ?: ""

    val messages: StateFlow<List<DMMessage>> = dmService.messagesForConversation(counterpartyPubkey)

    val counterpartyProfile: StateFlow<FeedProfile?> = nostrService.profiles
        .map { it[counterpartyPubkey] }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    /** Full profile map, for resolving nostr: mentions inside message bodies. */
    val profiles: StateFlow<Map<String, FeedProfile>> = nostrService.profiles

    val myPubkey: String get() = configStore.activeAccountHexPubkey.value

    /** Whether this conversation already contains any NIP-04 (legacy) messages. */
    val hasNIP04Messages: StateFlow<Boolean> = messages
        .map { msgs -> msgs.any { it.isNIP04 } }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

    /** Selected send protocol. false = NIP-17 (default, encrypted), true = NIP-04 (legacy). */
    private val _useNIP04 = MutableStateFlow(false)
    val useNIP04 = _useNIP04.asStateFlow()

    /** The message box. A send clears it and a failed one hands the text back. */
    val messageField = TextFieldState()

    private val _isSending = MutableStateFlow(false)
    val isSending = _isSending.asStateFlow()

    private val _attachedImage = MutableStateFlow<Uri?>(null)
    val attachedImage = _attachedImage.asStateFlow()

    /** Why this account can't use DMs, or null when it can. See DMService.dmUnavailable. */
    val dmUnavailable: StateFlow<String?> = dmService.dmUnavailable

    /** Set when a send fails; the screen shows it in the "Failed to Send" alert. */
    private val _sendError = MutableStateFlow<String?>(null)
    val sendError = _sendError.asStateFlow()
    fun clearSendError() { _sendError.value = null }

    /** Called while the thread is on screen, so its notifications stay quiet. */
    fun setVisible(visible: Boolean) {
        if (visible) {
            dmService.visibleConversation = counterpartyPubkey
        } else if (dmService.visibleConversation == counterpartyPubkey) {
            dmService.visibleConversation = null
        }
    }

    init {
        viewModelScope.launch {
            nostrService.fetchMissingProfiles(listOf(counterpartyPubkey))
            dmService.markConversationRead(counterpartyPubkey)
        }
        // Drain any queued (Amber) decrypts while the thread is open so newly
        // arrived messages appear without leaving the conversation.
        viewModelScope.launch {
            dmService.decryptPending()
            dmService.pendingDecryptCount.collect { if (it > 0) dmService.decryptPending() }
        }
    }

    fun setMessageText(text: String) { messageField.setTextAndPlaceCursorAtEnd(text) }

    fun setAttachedImage(uri: Uri?) {
        if (_attachedImage.value != uri) DMPastedImage.discard(_attachedImage.value)
        _attachedImage.value = uri
    }
    fun clearAttachedImage() = setAttachedImage(null)

    /** A photo pasted, dropped or sent from the keyboard: copied, then attached like a picked one. */
    fun attachPastedImage(uri: Uri) {
        if (_isSending.value) return
        viewModelScope.launch {
            val copy = DMPastedImage.copy(context, uri)
            if (copy == null) {
                _sendError.value = "Couldn't read that photo."
            } else {
                setAttachedImage(copy)
            }
        }
    }

    override fun onCleared() {
        DMPastedImage.discard(_attachedImage.value)
    }

    fun toggleProtocol() { _useNIP04.value = !_useNIP04.value }

    fun sendMessage() {
        val text = messageField.text.toString().trim()
        val image = _attachedImage.value
        if ((text.isBlank() && image == null) || _isSending.value) return

        viewModelScope.launch {
            _isSending.value = true
            messageField.clearText()
            _attachedImage.value = null
            try {
                // The photo goes up first: a message naming a URL no server
                // holds would reach them as a dead link (as iOS).
                val imageUrl = image?.let { uploadImage(it) ?: throw DMPhotoUploadException() }
                val content = buildString {
                    append(text)
                    if (imageUrl != null) {
                        if (text.isNotEmpty()) append("\n")
                        append(imageUrl)
                    }
                }
                if (content.isNotEmpty()) {
                    dmService.sendMessage(counterpartyPubkey, content, _useNIP04.value)
                }
                DMPastedImage.discard(image)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // Hand the message back unless something new was typed meanwhile.
                if (messageField.text.isEmpty()) messageField.setTextAndPlaceCursorAtEnd(text)
                if (_attachedImage.value == null) _attachedImage.value = image else DMPastedImage.discard(image)
                _sendError.value = DMSendFailure.message(e)
            } finally {
                _isSending.value = false
            }
        }
    }

    private suspend fun uploadImage(uri: Uri): String? = withContext(Dispatchers.IO) {
        try {
            val input = context.contentResolver.openInputStream(uri) ?: return@withContext null
            val tempFile = File.createTempFile("dm_upload_", ".tmp", context.cacheDir)
            tempFile.outputStream().use { out -> input.use { it.copyTo(out) } }
            val contentType = context.contentResolver.getType(uri)
                ?: DMPastedImage.mimeType(uri)
                ?: "image/jpeg"
            if (!MediaPrivacy.removeLocation(tempFile, contentType)) {
                tempFile.delete()
                return@withContext null
            }
            val sha256 = blossomService.computeSHA256(tempFile)
            val url = blossomService.uploadAndMirror(tempFile, sha256, contentType)
            tempFile.delete()
            url
        } catch (_: Exception) {
            null
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DMThreadScreen(
    counterpartyPubkey: String,
    onProfileClick: (String) -> Unit,
    /** Null in the inbox's two-pane layout, where there is nothing to go back to. */
    onBack: (() -> Unit)?,
    /** Typed into the message box on open, for the owner to edit or send. */
    initialMessage: String? = null,
    viewModel: DMThreadViewModel = hiltViewModel(),
) {
    LaunchedEffect(initialMessage) {
        if (initialMessage != null && viewModel.messageField.text.isEmpty()) {
            viewModel.setMessageText(initialMessage)
        }
    }
    val messages by viewModel.messages.collectAsState()
    val counterpartyProfile by viewModel.counterpartyProfile.collectAsState()
    val profiles by viewModel.profiles.collectAsState()
    val isSending by viewModel.isSending.collectAsState()
    val useNIP04 by viewModel.useNIP04.collectAsState()
    val hasNIP04Messages by viewModel.hasNIP04Messages.collectAsState()
    val attachedImage by viewModel.attachedImage.collectAsState()
    val sendError by viewModel.sendError.collectAsState()
    val dmUnavailable by viewModel.dmUnavailable.collectAsState()
    val listState = rememberLazyListState()
    val colors = LocalNostrVaultColors.current

    val imagePicker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickVisualMedia(),
    ) { uri -> uri?.let { viewModel.setAttachedImage(it) } }

    sendError?.let { DMSendFailedDialog(it, onDismiss = viewModel::clearSendError) }

    DisposableEffect(viewModel) {
        viewModel.setVisible(true)
        onDispose { viewModel.setVisible(false) }
    }

    // Scroll to bottom on new messages
    LaunchedEffect(messages.size) {
        if (messages.isNotEmpty()) {
            listState.animateScrollToItem(messages.size - 1)
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.clickable { onProfileClick(counterpartyPubkey) },
                    ) {
                        // iOS: a 28pt avatar with the generated fallback, name in 15 semibold.
                        AvatarImage(
                            url = counterpartyProfile?.pictureURL,
                            pubkey = counterpartyPubkey,
                            size = 28.dp,
                            displayName = counterpartyProfile?.bestName,
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(
                            text = counterpartyProfile?.bestName
                                ?: counterpartyPubkey.take(8) + "\u2026",
                            fontSize = 15.sp,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                },
                navigationIcon = {
                    if (onBack != null) {
                        IconButton(onClick = onBack) {
                            Icon(NostrVaultIcons.Back, contentDescription = "Back")
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = WindowBackground,
                    titleContentColor = PrimaryText,
                    navigationIconContentColor = PrimaryText,
                ),
            )
        },
        bottomBar = {
            Column {
                // Watch-only: there is no key on this device to seal a message
                // with, so the box is replaced by the reason rather than
                // letting every send fail into an alert.
                val blocked = dmUnavailable
                if (blocked != null) {
                    DMUnavailableNotice(blocked)
                } else {
                    ProtocolToggleRow(
                        useNIP04 = useNIP04,
                        onToggle = viewModel::toggleProtocol,
                    )
                    MessageInputBar(
                        field = viewModel.messageField,
                        isSending = isSending,
                        attachedImage = attachedImage,
                        onPasteImage = viewModel::attachPastedImage,
                        onSend = viewModel::sendMessage,
                        onPickImage = {
                            imagePicker.launch(
                                PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly),
                            )
                        },
                        onClearImage = viewModel::clearAttachedImage,
                    )
                }
            }
        },
        containerColor = WindowBackground,
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
        ) {
            if (hasNIP04Messages) {
                NIP04WarningBanner()
            }

            if (messages.isEmpty()) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier.fillMaxSize(),
                ) {
                    Text(
                        text = "Start a conversation",
                        color = SecondaryText,
                        fontSize = 15.sp,
                    )
                }
            } else {
                LazyColumn(
                    state = listState,
                    // iOS spacing: 10 between bubbles, 12 at the sides.
                    contentPadding = PaddingValues(horizontal = 12.dp, vertical = 16.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                    modifier = Modifier.fillMaxSize(),
                ) {
                    items(
                        items = messages,
                        key = { it.id },
                    ) { message ->
                        MessageBubble(
                            message = message,
                            isFromMe = message.senderPubkey == viewModel.myPubkey,
                            profiles = profiles,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun NIP04WarningBanner() {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier
            .fillMaxWidth()
            .background(ZapOrange.copy(alpha = 0.08f))
            .padding(horizontal = 14.dp, vertical = 8.dp),
    ) {
        Icon(
            imageVector = NostrVaultIcons.Alert,
            contentDescription = null,
            tint = ZapOrange.copy(alpha = 0.9f),
            modifier = Modifier.size(13.dp),
        )
        Text(
            text = "Some messages use NIP-04 (legacy encryption). New messages default to NIP-17.",
            color = ZapOrange.copy(alpha = 0.9f),
            fontSize = 11.sp,
            fontWeight = FontWeight.Medium,
        )
    }
}

@Composable
private fun ProtocolToggleRow(
    useNIP04: Boolean,
    onToggle: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    Surface(color = WindowBackground) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 6.dp),
        ) {
            Icon(
                imageVector = if (useNIP04) NostrVaultIcons.LockOpen else NostrVaultIcons.Lock,
                contentDescription = null,
                tint = if (useNIP04) ZapOrange.copy(alpha = 0.8f) else colors.primary.copy(alpha = 0.7f),
                modifier = Modifier.size(12.dp),
            )
            Text(
                text = if (useNIP04) "NIP-04 (legacy)" else "NIP-17 (encrypted)",
                color = SecondaryText.copy(alpha = 0.8f),
                fontSize = 11.sp,
                fontWeight = FontWeight.Medium,
            )
            Spacer(Modifier.weight(1f))
            Text(
                text = "Switch",
                color = colors.primary,
                fontSize = 11.sp,
                fontWeight = FontWeight.Medium,
                modifier = Modifier.clickable(onClick = onToggle),
            )
        }
    }
}

@Composable
private fun MessageBubble(
    message: DMMessage,
    isFromMe: Boolean,
    profiles: Map<String, FeedProfile> = emptyMap(),
) {
    val colors = LocalNostrVaultColors.current
    val oled = LocalOledMode.current

    // iOS DMThreadView bubbles: own = solid primary→primaryDark gradient with
    // white text, others = dark gray; 75% max width, radius 18 with a 6dp tail.
    val bubbleShape = RoundedCornerShape(
        topStart = 18.dp,
        topEnd = 18.dp,
        bottomStart = if (isFromMe) 18.dp else 6.dp,
        bottomEnd = if (isFromMe) 6.dp else 18.dp,
    )
    val otherBubbleColor = if (oled) Color(0xFF14141A) else Color(0xFF292933)

    // A photo sent as its Blossom link shows as the photo; tap opens the viewer (iOS #288).
    val parts = remember(message.content) { DMAttachment.split(message.content) }
    val zoomOrigin = remember { MediaZoomSources.newOrigin() }
    val showText = parts.text.isNotEmpty() || parts.images.isEmpty()

    BoxWithConstraints(modifier = Modifier.fillMaxWidth()) {
        val maxBubbleWidth = maxWidth * 0.75f
        val photoSize = minOf(240.dp, maxWidth * 0.6f)
        // iOS: who sent it, a 28pt avatar beside their bubbles, level with the time.
        Row(verticalAlignment = Alignment.Bottom, modifier = Modifier.fillMaxWidth()) {
            if (!isFromMe) {
                val sender = profiles[message.senderPubkey]
                if (sender != null) {
                    AvatarImage(
                        url = sender.pictureURL,
                        pubkey = message.senderPubkey,
                        size = 28.dp,
                        displayName = sender.bestName,
                    )
                } else {
                    Box(Modifier.size(28.dp).background(SecondaryText.copy(alpha = 0.2f), CircleShape))
                }
                Spacer(Modifier.width(8.dp))
            }
            Column(
                horizontalAlignment = if (isFromMe) Alignment.End else Alignment.Start,
                modifier = Modifier.weight(1f),
            ) {
                Column(
                    modifier = Modifier
                        .widthIn(max = maxBubbleWidth)
                        .clip(bubbleShape)
                        .background(
                            brush = if (isFromMe) {
                                Brush.linearGradient(listOf(colors.primary, colors.primaryDark))
                            } else {
                                Brush.linearGradient(listOf(otherBubbleColor, otherBubbleColor))
                            },
                        ),
                ) {
                    parts.images.forEachIndexed { index, url ->
                        RetryableAsyncImage(
                            model = url,
                            contentDescription = "Photo",
                            contentScale = ContentScale.Crop,
                            modifier = Modifier
                                .size(photoSize)
                                .mediaZoomSource(MediaSourceKey(zoomOrigin, index), crop = true)
                                .clickable { FullScreenMediaRouter.open(parts.images, index, zoomOrigin) },
                        )
                    }
                    if (showText) {
                        // Long-press selects, as iOS .textSelection(.enabled). The
                        // accent-colored selection would vanish on our own accent
                        // bubble, so it is white there.
                        val selectionColors = if (isFromMe) {
                            TextSelectionColors(handleColor = Color.White, backgroundColor = Color.White.copy(alpha = 0.35f))
                        } else {
                            TextSelectionColors(handleColor = colors.primary, backgroundColor = colors.primary.copy(alpha = 0.4f))
                        }
                        CompositionLocalProvider(LocalTextSelectionColors provides selectionColors) {
                            SelectionContainer {
                                Text(
                                    text = remember(parts.text, profiles) {
                                        NostrMentions.toPlainText(parts.text, profiles)
                                    },
                                    color = Color.White,
                                    fontSize = 15.sp,
                                    lineHeight = 20.sp,
                                    modifier = Modifier.padding(
                                        start = 14.dp,
                                        end = 14.dp,
                                        top = 10.dp,
                                        bottom = if (message.isNIP04) 4.dp else 10.dp,
                                    ),
                                )
                            }
                        }
                    }
                    if (message.isNIP04) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(3.dp),
                            modifier = Modifier.padding(
                                start = 14.dp,
                                end = 14.dp,
                                top = if (showText) 0.dp else 8.dp,
                                bottom = 10.dp,
                            ),
                        ) {
                            Icon(
                                imageVector = NostrVaultIcons.LockOpen,
                                contentDescription = null,
                                tint = ZapOrange.copy(alpha = 0.8f),
                                modifier = Modifier.size(10.dp),
                            )
                            Text(
                                text = "NIP-04",
                                color = ZapOrange.copy(alpha = 0.8f),
                                fontSize = 10.sp,
                                fontWeight = FontWeight.Medium,
                            )
                        }
                    }
                }
                Spacer(Modifier.height(3.dp))
                Text(
                    // iOS: relative, "5 minutes ago".
                    text = RelativeTime.numeric(message.timestamp, System.currentTimeMillis() / 1000),
                    color = SecondaryText.copy(alpha = 0.7f),
                    fontSize = 11.sp,
                )
            }
        }
    }
}

@Composable
private fun MessageInputBar(
    field: TextFieldState,
    isSending: Boolean,
    attachedImage: Uri?,
    onPasteImage: (Uri) -> Unit,
    onSend: () -> Unit,
    onPickImage: () -> Unit,
    onClearImage: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    val canSend = (field.text.isNotBlank() || attachedImage != null) && !isSending

    Surface(
        color = SecondaryGroupedBg,
        tonalElevation = 2.dp,
    ) {
        Column(modifier = Modifier.navigationBarsPadding()) {
            // Attached image preview
            attachedImage?.let { uri ->
                Box(modifier = Modifier.padding(start = 12.dp, top = 8.dp)) {
                    AsyncImage(
                        model = uri,
                        contentDescription = "Attached image",
                        contentScale = ContentScale.Crop,
                        modifier = Modifier
                            .size(64.dp)
                            .clip(RoundedCornerShape(10.dp)),
                    )
                    IconButton(
                        onClick = onClearImage,
                        enabled = !isSending,
                        modifier = Modifier
                            .align(Alignment.TopEnd)
                            .size(22.dp),
                    ) {
                        Icon(
                            imageVector = NostrVaultIcons.Dismiss,
                            contentDescription = "Remove image",
                            tint = PrimaryText,
                            modifier = Modifier.size(16.dp),
                        )
                    }
                }
            }

            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 12.dp, vertical = 8.dp),
            ) {
                IconButton(onClick = onPickImage, enabled = !isSending) {
                    Icon(
                        imageVector = NostrVaultIcons.Media,
                        contentDescription = "Attach image",
                        tint = colors.primary,
                    )
                }

                DMMessageField(
                    state = field,
                    onPasteImage = { if (!isSending) onPasteImage(it) },
                    modifier = Modifier.weight(1f),
                )

                Spacer(Modifier.width(8.dp))

                // iOS: a white arrow in a filled circle, purple when it can send.
                IconButton(
                    onClick = onSend,
                    enabled = canSend,
                ) {
                    if (isSending) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(20.dp),
                            strokeWidth = 2.dp,
                            color = colors.primary,
                        )
                    } else {
                        Box(
                            contentAlignment = Alignment.Center,
                            modifier = Modifier
                                .size(34.dp)
                                .background(
                                    if (canSend) colors.primary else SecondaryText.copy(alpha = 0.25f),
                                    CircleShape,
                                ),
                        ) {
                            Icon(
                                imageVector = NostrVaultIcons.ArrowUp,
                                contentDescription = "Send",
                                tint = Color.White,
                                modifier = Modifier.size(18.dp),
                            )
                        }
                    }
                }
            }
        }
    }
}
