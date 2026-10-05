package com.nostrvault.ui.screens.dm

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
import com.nostrvault.service.NostrService
import com.nostrvault.ui.components.NostrMentions
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.text.SimpleDateFormat
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

    private val _messageText = MutableStateFlow("")
    val messageText = _messageText.asStateFlow()

    private val _isSending = MutableStateFlow(false)
    val isSending = _isSending.asStateFlow()

    private val _attachedImage = MutableStateFlow<Uri?>(null)
    val attachedImage = _attachedImage.asStateFlow()

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

    fun setMessageText(text: String) { _messageText.value = text }

    fun setAttachedImage(uri: Uri?) { _attachedImage.value = uri }
    fun clearAttachedImage() { _attachedImage.value = null }

    fun toggleProtocol() { _useNIP04.value = !_useNIP04.value }

    fun sendMessage() {
        val text = _messageText.value.trim()
        val image = _attachedImage.value
        if ((text.isBlank() && image == null) || _isSending.value) return

        viewModelScope.launch {
            _isSending.value = true
            _messageText.value = ""
            _attachedImage.value = null
            val imageUrl = image?.let { uploadImage(it) }
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
            _isSending.value = false
        }
    }

    private suspend fun uploadImage(uri: Uri): String? = withContext(Dispatchers.IO) {
        try {
            val input = context.contentResolver.openInputStream(uri) ?: return@withContext null
            val tempFile = File.createTempFile("dm_upload_", ".tmp", context.cacheDir)
            tempFile.outputStream().use { out -> input.use { it.copyTo(out) } }
            val sha256 = blossomService.computeSHA256(tempFile)
            val contentType = context.contentResolver.getType(uri) ?: "image/jpeg"
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
    onBack: () -> Unit,
    /** Typed into the message box on open, for the owner to edit or send. */
    initialMessage: String? = null,
    viewModel: DMThreadViewModel = hiltViewModel(),
) {
    LaunchedEffect(initialMessage) {
        if (initialMessage != null && viewModel.messageText.value.isEmpty()) {
            viewModel.setMessageText(initialMessage)
        }
    }
    val messages by viewModel.messages.collectAsState()
    val counterpartyProfile by viewModel.counterpartyProfile.collectAsState()
    val profiles by viewModel.profiles.collectAsState()
    val messageText by viewModel.messageText.collectAsState()
    val isSending by viewModel.isSending.collectAsState()
    val useNIP04 by viewModel.useNIP04.collectAsState()
    val hasNIP04Messages by viewModel.hasNIP04Messages.collectAsState()
    val attachedImage by viewModel.attachedImage.collectAsState()
    val listState = rememberLazyListState()
    val colors = LocalNostrVaultColors.current

    val imagePicker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickVisualMedia(),
    ) { uri -> uri?.let { viewModel.setAttachedImage(it) } }

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
                        AsyncImage(
                            model = counterpartyProfile?.pictureURL,
                            contentDescription = null,
                            contentScale = ContentScale.Crop,
                            modifier = Modifier
                                .size(32.dp)
                                .clip(CircleShape),
                        )
                        Spacer(Modifier.width(10.dp))
                        Text(
                            text = counterpartyProfile?.bestName
                                ?: counterpartyPubkey.take(8) + "...",
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(NostrVaultIcons.Back, contentDescription = "Back")
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
                ProtocolToggleRow(
                    useNIP04 = useNIP04,
                    onToggle = viewModel::toggleProtocol,
                )
                MessageInputBar(
                    text = messageText,
                    isSending = isSending,
                    attachedImage = attachedImage,
                    onTextChange = viewModel::setMessageText,
                    onSend = viewModel::sendMessage,
                    onPickImage = {
                        imagePicker.launch(
                            PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly),
                        )
                    },
                    onClearImage = viewModel::clearAttachedImage,
                )
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
                    contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
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
    val timeFormat = remember { SimpleDateFormat("h:mm a", Locale.getDefault()) }

    // iOS DMThreadView bubbles: own = solid primary→primaryDark gradient with
    // white text, others = dark gray; 75% max width, radius 18 with a 6dp tail.
    val bubbleShape = RoundedCornerShape(
        topStart = 18.dp,
        topEnd = 18.dp,
        bottomStart = if (isFromMe) 18.dp else 6.dp,
        bottomEnd = if (isFromMe) 6.dp else 18.dp,
    )
    val otherBubbleColor = if (oled) Color(0xFF14141A) else Color(0xFF292933)

    BoxWithConstraints(modifier = Modifier.fillMaxWidth()) {
        val maxBubbleWidth = maxWidth * 0.75f
        Column(
            horizontalAlignment = if (isFromMe) Alignment.End else Alignment.Start,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(
                modifier = Modifier
                    .widthIn(max = maxBubbleWidth)
                    .background(
                        brush = if (isFromMe) {
                            Brush.linearGradient(listOf(colors.primary, colors.primaryDark))
                        } else {
                            Brush.linearGradient(listOf(otherBubbleColor, otherBubbleColor))
                        },
                        shape = bubbleShape,
                    )
                    .padding(horizontal = 14.dp, vertical = 10.dp),
            ) {
                Text(
                    text = remember(message.content, profiles) {
                        NostrMentions.toPlainText(message.content, profiles)
                    },
                    color = Color.White,
                    fontSize = 15.sp,
                    lineHeight = 20.sp,
                )
                if (message.isNIP04) {
                    Spacer(Modifier.height(4.dp))
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(3.dp),
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
                text = timeFormat.format(Date(message.timestamp * 1000)),
                color = SecondaryText.copy(alpha = 0.7f),
                fontSize = 11.sp,
            )
        }
    }
}

@Composable
private fun MessageInputBar(
    text: String,
    isSending: Boolean,
    attachedImage: Uri?,
    onTextChange: (String) -> Unit,
    onSend: () -> Unit,
    onPickImage: () -> Unit,
    onClearImage: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    val canSend = (text.isNotBlank() || attachedImage != null) && !isSending

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
                            .size(72.dp)
                            .clip(RoundedCornerShape(10.dp)),
                    )
                    IconButton(
                        onClick = onClearImage,
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

                OutlinedTextField(
                    value = text,
                    onValueChange = onTextChange,
                    placeholder = { Text("Message", color = PlaceholderText) },
                    maxLines = 4,
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = colors.primary,
                        unfocusedBorderColor = SeparatorColor,
                        cursorColor = colors.primary,
                    ),
                    shape = RoundedCornerShape(20.dp),
                    modifier = Modifier.weight(1f),
                )

                Spacer(Modifier.width(8.dp))

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
                        Icon(
                            imageVector = NostrVaultIcons.Send,
                            contentDescription = "Send",
                            tint = if (canSend) colors.primary else TertiaryText,
                        )
                    }
                }
            }
        }
    }
}
