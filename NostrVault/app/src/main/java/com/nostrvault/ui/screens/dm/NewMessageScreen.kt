package com.nostrvault.ui.screens.dm

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.TextStyle
import com.nostrvault.ui.components.AvatarImage
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import android.content.Context
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import coil.compose.AsyncImage
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.BlossomService
import com.nostrvault.service.DMService
import com.nostrvault.service.MediaPrivacy
import com.nostrvault.service.NostrService
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import javax.inject.Inject

/**
 * Compose a brand-new DM, picking a recipient by profile search or npub.
 * Port of MessageComposerView.swift (iOS new-message composer).
 */

@HiltViewModel
class NewMessageViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    @ApplicationContext private val context: Context,
    private val dmService: DMService,
    private val nostrService: NostrService,
    private val blossomService: BlossomService,
) : ViewModel() {

    /** Optional pre-locked recipient (e.g. opened from a profile). null = free picker. */
    private val lockedRecipient: String? = savedStateHandle["pubkey"]

    val profiles: StateFlow<Map<String, FeedProfile>> = nostrService.profiles

    private val _selectedRecipient = MutableStateFlow(lockedRecipient)
    val selectedRecipient: StateFlow<String?> = _selectedRecipient.asStateFlow()

    private val _searchText = MutableStateFlow("")
    val searchText: StateFlow<String> = _searchText.asStateFlow()

    private val _messageText = MutableStateFlow("")
    val messageText: StateFlow<String> = _messageText.asStateFlow()

    private val _isSending = MutableStateFlow(false)
    val isSending: StateFlow<Boolean> = _isSending.asStateFlow()

    private val _attachedImage = MutableStateFlow<Uri?>(null)
    val attachedImage: StateFlow<Uri?> = _attachedImage.asStateFlow()

    /** Set when a send fails; the screen shows it in the "Failed to Send" alert. */
    private val _sendError = MutableStateFlow<String?>(null)
    val sendError: StateFlow<String?> = _sendError.asStateFlow()
    fun clearSendError() { _sendError.value = null }

    /** Search results: npub decode (single hit) or name/pubkey substring filter (cap 10). */
    val searchResults: StateFlow<List<String>> =
        combine(_searchText, nostrService.profiles) { query, profs ->
            val q = query.trim()
            if (q.length < 2) return@combine emptyList()
            val lower = q.lowercase()

            if (lower.startsWith("npub1")) {
                HavenBridge.decodeNpub(q)?.let { return@combine listOf(it) }
            }

            profs.keys.filter { pubkey ->
                val name = profs[pubkey]?.bestName ?: ""
                name.lowercase().contains(lower) || pubkey.lowercase().contains(lower)
            }.take(10)
        }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val canSend: StateFlow<Boolean> =
        combine(_messageText, _selectedRecipient, _attachedImage) { msg, recipient, image ->
            recipient != null && (msg.trim().isNotEmpty() || image != null)
        }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

    init {
        viewModelScope.launch {
            lockedRecipient?.let { nostrService.fetchMissingProfiles(listOf(it)) }
        }
    }

    fun profileFor(pubkey: String): FeedProfile? = profiles.value[pubkey]

    fun setSearchText(text: String) { _searchText.value = text }

    fun selectRecipient(pubkey: String) {
        _selectedRecipient.value = pubkey
        _searchText.value = ""
        viewModelScope.launch { nostrService.fetchMissingProfiles(listOf(pubkey)) }
    }

    /** Recipient can only be cleared when it wasn't pre-locked. */
    fun clearRecipient() {
        if (lockedRecipient == null) _selectedRecipient.value = null
    }

    fun setMessageText(text: String) { _messageText.value = text }

    fun setAttachedImage(uri: Uri?) { _attachedImage.value = uri }
    fun clearAttachedImage() { _attachedImage.value = null }

    fun send(onSent: (String) -> Unit) {
        val recipient = _selectedRecipient.value ?: return
        val text = _messageText.value.trim()
        val image = _attachedImage.value
        if ((text.isEmpty() && image == null) || _isSending.value) return

        viewModelScope.launch {
            _isSending.value = true
            try {
                // A photo that failed to upload stops the send, as iOS does,
                // instead of sending the text alone or a blank DM.
                val imageUrl = image?.let { uploadImage(it) ?: throw DMPhotoUploadException() }
                val content = buildString {
                    append(text)
                    if (imageUrl != null) {
                        if (text.isNotEmpty()) append("\n")
                        append(imageUrl)
                    }
                }
                if (content.isNotEmpty()) {
                    dmService.sendDM(content, recipient)
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // The text and photo were never cleared, so they stay in the box.
                _sendError.value = DMSendFailure.message(e)
                return@launch
            } finally {
                _isSending.value = false
            }
            onSent(recipient)
        }
    }

    private suspend fun uploadImage(uri: Uri): String? = withContext(Dispatchers.IO) {
        try {
            val input = context.contentResolver.openInputStream(uri) ?: return@withContext null
            val tempFile = File.createTempFile("dm_upload_", ".tmp", context.cacheDir)
            tempFile.outputStream().use { out -> input.use { it.copyTo(out) } }
            val contentType = context.contentResolver.getType(uri) ?: "image/jpeg"
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
fun NewMessageScreen(
    onMessageSent: (String) -> Unit,
    onBack: () -> Unit,
    viewModel: NewMessageViewModel = hiltViewModel(),
) {
    val selectedRecipient by viewModel.selectedRecipient.collectAsState()
    val searchText by viewModel.searchText.collectAsState()
    val searchResults by viewModel.searchResults.collectAsState()
    val messageText by viewModel.messageText.collectAsState()
    val isSending by viewModel.isSending.collectAsState()
    val canSend by viewModel.canSend.collectAsState()
    val attachedImage by viewModel.attachedImage.collectAsState()
    val sendError by viewModel.sendError.collectAsState()
    val colors = LocalNostrVaultColors.current

    sendError?.let { DMSendFailedDialog(it, onDismiss = viewModel::clearSendError) }

    val imagePicker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickVisualMedia(),
    ) { uri -> uri?.let { viewModel.setAttachedImage(it) } }

    // iOS MessageComposerView: Cancel and the title on top, the recipient
    // card, the message, then a Send capsule at the bottom right. The photo
    // button is Android's (iOS has none yet) and sits opposite Send.
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("New Message") },
                navigationIcon = {
                    TextButton(onClick = onBack) {
                        Text("Cancel", color = colors.primary)
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = WindowBackground,
                    titleContentColor = PrimaryText,
                ),
            )
        },
        containerColor = WindowBackground,
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .imePadding(),
        ) {
            val recipient = selectedRecipient
            if (recipient != null) {
                RecipientChip(
                    pubkey = recipient,
                    profile = viewModel.profileFor(recipient),
                    onClear = { viewModel.clearRecipient() },
                )
            } else {
                RecipientSearch(
                    searchText = searchText,
                    onSearchChange = viewModel::setSearchText,
                    results = searchResults,
                    profileFor = viewModel::profileFor,
                    onPick = viewModel::selectRecipient,
                )
            }

            HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp)

            Column(
                modifier = Modifier
                    .weight(1f)
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 4.dp),
            ) {
                Box(Modifier.padding(12.dp)) {
                    BasicTextField(
                        value = messageText,
                        onValueChange = viewModel::setMessageText,
                        textStyle = TextStyle(color = PrimaryText, fontSize = 15.sp),
                        cursorBrush = SolidColor(colors.primary),
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = 120.dp)
                            .padding(horizontal = 5.dp, vertical = 8.dp),
                    )
                    if (messageText.isEmpty()) {
                        Text(
                            "Write a message...",
                            color = SecondaryText.copy(alpha = 0.5f),
                            fontSize = 15.sp,
                            modifier = Modifier.padding(horizontal = 5.dp, vertical = 8.dp),
                        )
                    }
                }

                attachedImage?.let { uri ->
                    Box(modifier = Modifier.padding(horizontal = 12.dp)) {
                        AsyncImage(
                            model = uri,
                            contentDescription = "Attached image",
                            contentScale = ContentScale.Crop,
                            modifier = Modifier
                                .fillMaxWidth()
                                .heightIn(max = 200.dp)
                                .clip(RoundedCornerShape(10.dp)),
                        )
                        IconButton(
                            onClick = { viewModel.clearAttachedImage() },
                            enabled = !isSending,
                            modifier = Modifier
                                .align(Alignment.TopEnd)
                                .padding(8.dp)
                                .size(24.dp),
                        ) {
                            Icon(
                                imageVector = NostrVaultIcons.Dismiss,
                                contentDescription = "Remove image",
                                tint = Color.White,
                                modifier = Modifier.size(22.dp),
                            )
                        }
                    }
                }
            }

            HorizontalDivider(color = SeparatorColor.copy(alpha = 0.5f), thickness = 0.5.dp)

            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 12.dp),
            ) {
                IconButton(
                    onClick = {
                        imagePicker.launch(
                            PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly),
                        )
                    },
                    enabled = !isSending,
                ) {
                    Icon(
                        imageVector = NostrVaultIcons.Media,
                        contentDescription = "Attach image",
                        tint = colors.primary,
                    )
                }
                Spacer(Modifier.weight(1f))
                if (isSending) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(20.dp),
                        strokeWidth = 2.dp,
                        color = colors.primary,
                    )
                } else {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .clip(CircleShape)
                            .background(if (canSend) colors.primary else colors.primary.copy(alpha = 0.3f))
                            .clickable(enabled = canSend, role = Role.Button) { viewModel.send(onMessageSent) }
                            .padding(horizontal = 18.dp, vertical = 10.dp),
                    ) {
                        Text("Send", color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                        Spacer(Modifier.width(6.dp))
                        Icon(
                            imageVector = NostrVaultIcons.Send,
                            contentDescription = null,
                            tint = Color.White,
                            modifier = Modifier.size(13.dp),
                        )
                    }
                }
            }
        }
    }
}

/** "To:" over a card holding the search field and, while typing, up to 200dp of matches. */
@Composable
private fun RecipientSearch(
    searchText: String,
    onSearchChange: (String) -> Unit,
    results: List<String>,
    profileFor: (String) -> FeedProfile?,
    onPick: (String) -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    Column(modifier = Modifier.padding(vertical = 16.dp)) {
        Text(
            "To:",
            color = SecondaryText,
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(horizontal = 16.dp),
        )
        Spacer(Modifier.height(8.dp))
        Column(
            modifier = Modifier
                .padding(horizontal = 16.dp)
                .fillMaxWidth()
                .clip(RoundedCornerShape(8.dp))
                .background(TertiaryGroupedBg),
        ) {
            Box(Modifier.padding(12.dp)) {
                BasicTextField(
                    value = searchText,
                    onValueChange = onSearchChange,
                    singleLine = true,
                    textStyle = TextStyle(color = PrimaryText, fontSize = 15.sp),
                    cursorBrush = SolidColor(colors.primary),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                    modifier = Modifier.fillMaxWidth(),
                )
                if (searchText.isEmpty()) Text("Search users...", color = PlaceholderText, fontSize = 15.sp)
            }
            if (searchText.isNotEmpty() && results.isNotEmpty()) {
                HorizontalDivider(color = SeparatorColor, thickness = 0.5.dp)
                LazyColumn(modifier = Modifier.heightIn(max = 200.dp)) {
                    itemsIndexed(items = results, key = { _, it -> it }) { index, pubkey ->
                        SearchResultRow(pubkey = pubkey, profile = profileFor(pubkey), onClick = { onPick(pubkey) })
                        if (index < results.lastIndex) {
                            HorizontalDivider(
                                color = SeparatorColor,
                                thickness = 0.5.dp,
                                modifier = Modifier.padding(start = 44.dp),
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SearchResultRow(
    pubkey: String,
    profile: FeedProfile?,
    onClick: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 10.dp),
    ) {
        AvatarImage(url = profile?.pictureURL, pubkey = pubkey, size = 32.dp, displayName = profile?.bestName)
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = profile?.bestName ?: pubkey.take(8),
                color = PrimaryText,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = pubkey.take(12) + "…",
                color = SecondaryText,
                fontSize = 11.sp,
                fontFamily = FontFamily.Monospace,
            )
        }
    }
}

/** The picked recipient on a card. Its X clears it, unless it came locked from a profile. */
@Composable
private fun RecipientChip(
    pubkey: String,
    profile: FeedProfile?,
    onClear: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .padding(horizontal = 16.dp, vertical = 12.dp)
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .background(TertiaryGroupedBg)
            .padding(12.dp),
    ) {
        AvatarImage(url = profile?.pictureURL, pubkey = pubkey, size = 32.dp, displayName = profile?.bestName)
        Spacer(Modifier.width(12.dp))
        Text(
            text = profile?.bestName ?: pubkey.take(8),
            color = PrimaryText,
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        IconButton(onClick = onClear, modifier = Modifier.size(28.dp)) {
            Icon(
                imageVector = NostrVaultIcons.Dismiss,
                contentDescription = "Clear recipient",
                tint = SecondaryText.copy(alpha = 0.6f),
                modifier = Modifier.size(18.dp),
            )
        }
    }
}
