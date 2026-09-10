package com.nostrvault.ui.screens

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import android.util.Log
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import coil.compose.AsyncImage
import com.nostrvault.data.model.Draft
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.service.BlossomService
import com.nostrvault.service.DraftService
import com.nostrvault.service.FeedService
import com.nostrvault.service.MediaItem
import com.nostrvault.service.MediaType
import com.nostrvault.service.NostrService
import com.nostrvault.service.PendingPostManager
import com.nostrvault.ui.components.QuotedNoteCard
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.security.MessageDigest
import javax.inject.Inject

/**
 * Compose new note screen with text input and publish action.
 * Supports replying to notes via NIP-10 e/p tags.
 */

data class Attachment(
    val id: String = java.util.UUID.randomUUID().toString(),
    val uri: Uri,
    val mimeType: String,
    val isVideo: Boolean = false,
    var uploadedUrl: String? = null,
    var isUploading: Boolean = false,
    var uploadProgress: Float = 0f,
)

@HiltViewModel
class ComposeNoteViewModel @Inject constructor(
    private val nostrService: NostrService,
    private val feedService: FeedService,
    private val pendingPostManager: PendingPostManager,
    private val draftService: DraftService,
    private val blossomService: BlossomService,
    private val configStore: ConfigStore,
    @ApplicationContext private val context: Context,
    savedStateHandle: SavedStateHandle,
) : ViewModel() {

    private val replyToNoteId: String? = savedStateHandle["replyTo"]
    private val quoteToNoteId: String? = savedStateHandle["quoteTo"]
    private val resumeDraftId: String? = savedStateHandle["draftId"]

    /** Stable draft ID for this compose session. */
    private val draftId: String = resumeDraftId ?: java.util.UUID.randomUUID().toString()
    private var autoSaveJob: Job? = null

    private val _content = MutableStateFlow("")
    val content = _content.asStateFlow()

    private val _isPublishing = MutableStateFlow(false)
    val isPublishing = _isPublishing.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error = _error.asStateFlow()

    /** Display name of the author being replied to (for UI hint). */
    private val _replyingToName = MutableStateFlow<String?>(null)
    val replyingToName = _replyingToName.asStateFlow()

    /** The quoted note and its author profile (for preview card). */
    private val _quotedNote = MutableStateFlow<FeedNote?>(null)
    val quotedNote = _quotedNote.asStateFlow()

    private val _quotedProfile = MutableStateFlow<FeedProfile?>(null)
    val quotedProfile = _quotedProfile.asStateFlow()

    private val _attachments = MutableStateFlow<List<Attachment>>(emptyList())
    val attachments = _attachments.asStateFlow()

    private val _isUploading = MutableStateFlow(false)
    val isUploading = _isUploading.asStateFlow()

    private val _uploadMessage = MutableStateFlow<String?>(null)
    val uploadMessage = _uploadMessage.asStateFlow()

    private val _showBlossomPicker = MutableStateFlow(false)
    val showBlossomPicker = _showBlossomPicker.asStateFlow()

    val isReply: Boolean get() = replyToNoteId != null
    val isQuote: Boolean get() = quoteToNoteId != null

    init {
        // Restore content from a resumed draft
        if (resumeDraftId != null) {
            val draft = draftService.findDraft(resumeDraftId)
            if (draft != null) {
                _content.value = draft.content
            }
        }

        if (replyToNoteId != null) {
            val parentNote = feedService.findNote(replyToNoteId)
            if (parentNote != null) {
                val profile = nostrService.profiles.value[parentNote.pubkey]
                _replyingToName.value = profile?.bestName ?: parentNote.pubkey.take(8) + "..."
            }
        }
        if (quoteToNoteId != null) {
            val quoted = feedService.findNote(quoteToNoteId)
            _quotedNote.value = quoted
            if (quoted != null) {
                _quotedProfile.value = nostrService.profiles.value[quoted.pubkey]
            }
            if (_content.value.isEmpty()) {
                _content.value = "\nnostr:${quoteToNoteId}"
            }
        }
    }

    fun setContent(text: String) {
        _content.value = text
        scheduleDraftSave()
    }

    fun addAttachments(uris: List<Uri>) {
        val newAttachments = uris.mapNotNull { uri ->
            val mimeType = context.contentResolver.getType(uri) ?: "application/octet-stream"
            val isVideo = mimeType.startsWith("video/")
            if (_attachments.value.size + 1 <= 4) {
                Attachment(uri = uri, mimeType = mimeType, isVideo = isVideo)
            } else null
        }
        _attachments.value = _attachments.value + newAttachments
    }

    fun removeAttachment(id: String) {
        _attachments.value = _attachments.value.filter { it.id != id }
    }

    fun setShowBlossomPicker(show: Boolean) {
        _showBlossomPicker.value = show
    }

    fun addBlossomMedia(url: String) {
        val currentContent = _content.value
        val newContent = if (currentContent.isEmpty() || currentContent.endsWith("\n") || currentContent.endsWith(" ")) {
            currentContent + url
        } else {
            "$currentContent $url"
        }
        _content.value = newContent
        _showBlossomPicker.value = false
    }

    fun handlePasteFromClipboard() {
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
        val clipData = clipboard?.primaryClip
        if (clipData != null && clipData.itemCount > 0) {
            val item = clipData.getItemAt(0)

            // Try URI first (images copied from gallery)
            item.uri?.let { uri ->
                if (_attachments.value.size < 4) {
                    addAttachments(listOf(uri))
                    return
                }
            }

            // Try text (could be a media URL)
            item.text?.toString()?.trim()?.let { text ->
                if (text.startsWith("http://") || text.startsWith("https://")) {
                    // Check if it's a media URL
                    val ext = text.substringAfterLast('.', "").lowercase()
                    val isMediaUrl = ext in listOf("jpg", "jpeg", "png", "gif", "webp", "mp4", "mov", "webm")
                    if (isMediaUrl && _attachments.value.size < 4) {
                        // Download and add as attachment
                        viewModelScope.launch {
                            downloadAndAttachUrl(text)
                        }
                        return
                    }
                }
                _error.value = "Clipboard does not contain an image or media URL"
            }
        } else {
            _error.value = "Clipboard is empty"
        }
    }

    private suspend fun downloadAndAttachUrl(url: String) = withContext(Dispatchers.IO) {
        try {
            val connection = java.net.URL(url).openConnection()
            connection.connect()
            val mimeType = connection.contentType ?: "application/octet-stream"
            val isVideo = mimeType.startsWith("video/")

            val tempFile = File.createTempFile("clipboard_", ".tmp", context.cacheDir)
            connection.getInputStream().use { input ->
                tempFile.outputStream().use { output ->
                    input.copyTo(output)
                }
            }

            val uri = Uri.fromFile(tempFile)
            withContext(Dispatchers.Main) {
                _attachments.value = _attachments.value + Attachment(
                    uri = uri,
                    mimeType = mimeType,
                    isVideo = isVideo
                )
            }
        } catch (e: Exception) {
            withContext(Dispatchers.Main) {
                _error.value = "Failed to download media from URL: ${e.message}"
            }
        }
    }

    suspend fun loadBlossomMediaItems(): List<MediaItem> = withContext(Dispatchers.IO) {
        try {
            val config = configStore.config.value
            val blossomDir = config.relayDataDir?.let { File(it, config.blossomPath) } ?: return@withContext emptyList()
            if (!blossomDir.exists()) return@withContext emptyList()

            val localBase = blossomService.localBlossomURL() ?: return@withContext emptyList()
            // Prefer an external mirror so the inserted URL is publicly accessible in published notes
            val externalBase = config.activeBlossomMirrors
                .firstOrNull { url -> !url.contains("localhost") && !url.contains("127.0.0.1") }
            val items = mutableListOf<MediaItem>()

            blossomDir.listFiles()?.forEach { file ->
                if (!file.isFile) return@forEach
                val filename = file.name
                if (filename.startsWith(".") || filename == "LOCK") return@forEach

                val sha256 = file.nameWithoutExtension
                if (sha256.length != 64 || !sha256.all { it in "0123456789abcdef" }) return@forEach

                val extension = file.extension.lowercase()
                val mediaType = when (extension) {
                    "jpg", "jpeg", "png", "gif", "webp" -> MediaType.IMAGE
                    "mp4", "mov", "webm", "avi" -> MediaType.VIDEO
                    "mp3", "m4a", "wav", "ogg" -> MediaType.AUDIO
                    else -> MediaType.UNKNOWN
                }

                if (mediaType != MediaType.UNKNOWN) {
                    // Use external mirror URL (BUD-01: {server}/{sha256}) so links work in published notes;
                    // fall back to local URL only when no mirrors are configured.
                    val insertUrl = if (externalBase != null) "$externalBase/$sha256" else "$localBase/$filename"
                    items.add(
                        MediaItem(
                            url = insertUrl,
                            type = mediaType,
                            pubkey = nostrService.ownerHexPubkey,
                            tags = null,
                            mimeType = null
                        )
                    )
                }
            }

            items.sortedByDescending { it.url }
        } catch (e: Exception) {
            Log.e("ComposeNote", "Failed to load blossom media items", e)
            emptyList()
        }
    }

    private fun scheduleDraftSave() {
        autoSaveJob?.cancel()
        autoSaveJob = viewModelScope.launch {
            delay(2000) // 2-second debounce
            val text = _content.value
            if (text.isNotBlank()) {
                draftService.saveDraft(
                    Draft(
                        id = draftId,
                        content = text,
                        replyToId = replyToNoteId,
                        quoteId = quoteToNoteId,
                    )
                )
            }
        }
    }

    fun publish(onPublished: () -> Unit) {
        val text = _content.value.trim()
        if (text.isBlank() && _attachments.value.isEmpty()) return

        viewModelScope.launch {
            _isPublishing.value = true
            _error.value = null
            try {
                // 1. Upload attachments first
                var finalContent = text
                if (_attachments.value.isNotEmpty()) {
                    _isUploading.value = true
                    val uploadedUrls = uploadAttachments()
                    _isUploading.value = false

                    if (uploadedUrls == null) {
                        _error.value = "Failed to upload media. Check your connection and try again."
                        _isPublishing.value = false
                        return@launch
                    }

                    // Append media URLs to content
                    uploadedUrls.forEach { url ->
                        finalContent += "\n$url"
                    }
                }

                // 2. Build tags
                val tags = buildReplyTags().toMutableList()
                if (quoteToNoteId != null) {
                    tags.add(listOf("q", quoteToNoteId))
                }

                // 3. Sign and publish
                val event = nostrService.signEventAsync(kind = 1, content = finalContent, tags = tags)
                if (event != null) {
                    val replyNote = replyToNoteId?.let { feedService.findNote(it) }
                    val quoteNote = quoteToNoteId?.let { feedService.findNote(it) }
                    pendingPostManager.startPost(
                        event = event,
                        content = finalContent,
                        replyTo = replyNote,
                        quoteTo = quoteNote,
                    ) { evt ->
                        nostrService.postEvent(evt)
                    }
                    // Delete draft on successful publish
                    autoSaveJob?.cancel()
                    draftService.deleteDraft(draftId)
                    onPublished()
                } else {
                    Log.e("ComposeNote", "signEventAsync returned null for kind=1")
                    _error.value = "Failed to sign note"
                }
            } catch (e: Exception) {
                Log.e("ComposeNote", "publish failed", e)
                _error.value = e.message ?: "Failed to publish"
            }
            _isPublishing.value = false
        }
    }

    private suspend fun uploadAttachments(): List<String>? = withContext(Dispatchers.IO) {
        val uploadedUrls = mutableListOf<String>()

        for ((index, attachment) in _attachments.value.withIndex()) {
            withContext(Dispatchers.Main) {
                val mediaType = if (attachment.isVideo) "video" else "image"
                _uploadMessage.value = "Uploading $mediaType (${index + 1} of ${_attachments.value.size})..."
            }

            try {
                // Read file from URI
                val inputStream = context.contentResolver.openInputStream(attachment.uri)
                    ?: return@withContext null

                val tempFile = File.createTempFile("upload_", ".tmp", context.cacheDir)
                tempFile.outputStream().use { output ->
                    inputStream.use { input ->
                        input.copyTo(output)
                    }
                }

                // Compute SHA-256
                val sha256 = blossomService.computeSHA256(tempFile)

                // Upload with progress
                val url = blossomService.uploadAndMirror(
                    fileURL = tempFile,
                    sha256 = sha256,
                    contentType = attachment.mimeType,
                    onProgress = { progress ->
                        viewModelScope.launch(Dispatchers.Main) {
                            val pct = (progress * 100).toInt()
                            val mediaType = if (attachment.isVideo) "video" else "image"
                            _uploadMessage.value = "Uploading $mediaType (${index + 1} of ${_attachments.value.size}) - $pct%..."
                        }
                    }
                )

                // Clean up temp file
                tempFile.delete()

                if (url != null) {
                    uploadedUrls.add(url)
                } else {
                    return@withContext null
                }
            } catch (e: Exception) {
                Log.e("ComposeNote", "Upload failed", e)
                return@withContext null
            }
        }

        withContext(Dispatchers.Main) {
            _uploadMessage.value = null
        }

        uploadedUrls
    }

    /**
     * Build NIP-10 reply tags (e-tags with root/reply markers + p-tag for author).
     * Returns empty list for new top-level notes.
     */
    private fun buildReplyTags(): List<List<String>> {
        val parentId = replyToNoteId ?: return emptyList()
        val parentNote = feedService.findNote(parentId) ?: return emptyList()

        val tags = mutableListOf<List<String>>()

        // Determine thread structure from parent's tags
        val parentETags = parentNote.tags.filter { it.size >= 2 && it[0] == "e" }
        val parentNonMentionETags = parentETags.filter { it.size < 4 || it[3] != "mention" }

        if (parentNonMentionETags.isEmpty()) {
            // Parent IS the root note — single e-tag with "root" marker
            tags.add(listOf("e", parentId, "", "root"))
        } else {
            // Parent is itself a reply — find the thread root
            val rootTag = parentNonMentionETags.firstOrNull { it.size >= 4 && it[3] == "root" }
            val threadRootId = rootTag?.get(1) ?: parentNonMentionETags[0][1]
            tags.add(listOf("e", threadRootId, "", "root"))
            tags.add(listOf("e", parentId, "", "reply"))
        }

        // Always tag the parent author
        tags.add(listOf("p", parentNote.pubkey))

        return tags
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ComposeNoteScreen(
    replyToNoteId: String? = null,
    onPublished: () -> Unit,
    onBack: () -> Unit,
    viewModel: ComposeNoteViewModel = hiltViewModel(),
) {
    val content by viewModel.content.collectAsState()
    val isPublishing by viewModel.isPublishing.collectAsState()
    val isUploading by viewModel.isUploading.collectAsState()
    val uploadMessage by viewModel.uploadMessage.collectAsState()
    val error by viewModel.error.collectAsState()
    val replyingToName by viewModel.replyingToName.collectAsState()
    val quotedNote by viewModel.quotedNote.collectAsState()
    val quotedProfile by viewModel.quotedProfile.collectAsState()
    val attachments by viewModel.attachments.collectAsState()
    val showBlossomPicker by viewModel.showBlossomPicker.collectAsState()
    val colors = LocalNostrVaultColors.current
    val context = LocalContext.current

    // Image picker launcher
    val imagePickerLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickMultipleVisualMedia(maxItems = 4 - attachments.size)
    ) { uris ->
        if (uris.isNotEmpty()) {
            viewModel.addAttachments(uris)
        }
    }

    // Video picker launcher
    val videoPickerLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickMultipleVisualMedia(maxItems = 4 - attachments.size)
    ) { uris ->
        if (uris.isNotEmpty()) {
            viewModel.addAttachments(uris)
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        when {
                            viewModel.isReply -> "Reply"
                            viewModel.isQuote -> "Quote"
                            else -> "New Note"
                        }
                    )
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(NostrVaultIcons.Dismiss, contentDescription = "Cancel")
                    }
                },
                actions = {
                    Button(
                        onClick = { viewModel.publish(onPublished) },
                        enabled = (content.isNotBlank() || attachments.isNotEmpty()) && !isPublishing && !isUploading,
                        colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
                        shape = RoundedCornerShape(20.dp),
                        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 8.dp),
                    ) {
                        if (isPublishing || isUploading) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(16.dp),
                                strokeWidth = 2.dp,
                                color = PrimaryText,
                            )
                        } else {
                            Text(
                                text = "Publish",
                                fontWeight = FontWeight.SemiBold,
                                color = PrimaryText,
                            )
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
        containerColor = WindowBackground,
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
        ) {
            // Reply context indicator
            replyingToName?.let { name ->
                Text(
                    text = "Replying to $name",
                    color = SecondaryText,
                    fontSize = 13.sp,
                )
                Spacer(Modifier.height(8.dp))
            }

            // Quoted note preview
            quotedNote?.let { qNote ->
                QuotedNoteCard(
                    note = qNote,
                    profile = quotedProfile,
                    onClick = { /* non-interactive in compose */ },
                    modifier = Modifier.padding(bottom = 12.dp),
                )
            }

            // Attachment grid preview
            if (attachments.isNotEmpty()) {
                AttachmentGrid(
                    attachments = attachments,
                    onRemove = { viewModel.removeAttachment(it) },
                    modifier = Modifier.padding(bottom = 12.dp)
                )
            }

            // Upload progress
            uploadMessage?.let { message ->
                if (isUploading) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(bottom = 12.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(16.dp),
                            strokeWidth = 2.dp,
                            color = colors.primary
                        )
                        Text(
                            text = message,
                            color = SecondaryText,
                            fontSize = 13.sp,
                            fontWeight = FontWeight.Medium
                        )
                    }
                }
            }

            // Error message
            error?.let { errMsg ->
                Surface(
                    color = ErrorRed.copy(alpha = 0.1f),
                    shape = RoundedCornerShape(8.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(
                        text = errMsg,
                        color = ErrorRed,
                        fontSize = 14.sp,
                        modifier = Modifier.padding(12.dp),
                    )
                }
                Spacer(Modifier.height(12.dp))
            }

            // Text input
            OutlinedTextField(
                value = content,
                onValueChange = viewModel::setContent,
                placeholder = {
                    Text(
                        when {
                            viewModel.isReply -> "Write your reply..."
                            viewModel.isQuote -> "Add your thoughts..."
                            else -> "What's on your mind?"
                        },
                        color = PlaceholderText,
                    )
                },
                minLines = 8,
                maxLines = 20,
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = Color.Transparent,
                    unfocusedBorderColor = Color.Transparent,
                    cursorColor = colors.primary,
                ),
                modifier = Modifier.fillMaxWidth(),
            )

            Spacer(Modifier.height(16.dp))

            // Media buttons footer
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                // Image picker button
                IconButton(
                    onClick = {
                        imagePickerLauncher.launch(
                            PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
                        )
                    },
                    modifier = Modifier
                        .size(40.dp)
                        .background(colors.primary.copy(alpha = 0.1f), CircleShape),
                    enabled = attachments.size < 4
                ) {
                    Icon(
                        imageVector = Icons.Default.Image,
                        contentDescription = "Add image",
                        tint = colors.primary,
                        modifier = Modifier.size(20.dp)
                    )
                }

                // Video picker button
                IconButton(
                    onClick = {
                        videoPickerLauncher.launch(
                            PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.VideoOnly)
                        )
                    },
                    modifier = Modifier
                        .size(40.dp)
                        .background(colors.primary.copy(alpha = 0.1f), CircleShape),
                    enabled = attachments.size < 4
                ) {
                    Icon(
                        imageVector = Icons.Default.Videocam,
                        contentDescription = "Add video",
                        tint = colors.primary,
                        modifier = Modifier.size(20.dp)
                    )
                }

                // Paste from clipboard button
                IconButton(
                    onClick = { viewModel.handlePasteFromClipboard() },
                    modifier = Modifier
                        .size(40.dp)
                        .background(colors.primary.copy(alpha = 0.1f), CircleShape),
                    enabled = attachments.size < 4
                ) {
                    Icon(
                        imageVector = Icons.Default.AutoAwesome,
                        contentDescription = "Paste from clipboard",
                        tint = colors.primary,
                        modifier = Modifier.size(20.dp)
                    )
                }

                Spacer(Modifier.weight(1f))

                // Blossom media picker button
                IconButton(
                    onClick = { viewModel.setShowBlossomPicker(true) },
                    modifier = Modifier
                        .size(40.dp)
                        .background(colors.primary.copy(alpha = 0.1f), CircleShape)
                ) {
                    Icon(
                        imageVector = Icons.Default.PhotoLibrary,
                        contentDescription = "Pick from Blossom",
                        tint = colors.primary,
                        modifier = Modifier.size(20.dp)
                    )
                }
            }

            Spacer(Modifier.height(12.dp))

            // Character count
            Text(
                text = "${content.length} characters",
                color = TertiaryText,
                fontSize = 12.sp,
                modifier = Modifier.align(Alignment.End),
            )
        }
    }

    // Blossom media picker sheet
    if (showBlossomPicker) {
        BlossomMediaPickerSheet(
            onDismiss = { viewModel.setShowBlossomPicker(false) },
            onSelect = { url -> viewModel.addBlossomMedia(url) }
        )
    }
}

@Composable
private fun AttachmentGrid(
    attachments: List<Attachment>,
    onRemove: (String) -> Unit,
    modifier: Modifier = Modifier
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        attachments.forEach { attachment ->
            Box(
                modifier = Modifier
                    .size(100.dp)
                    .clip(RoundedCornerShape(12.dp))
            ) {
                // Image/video preview
                AsyncImage(
                    model = attachment.uri,
                    contentDescription = null,
                    modifier = Modifier.fillMaxSize(),
                    contentScale = ContentScale.Crop
                )

                // Video indicator
                if (attachment.isVideo) {
                    Box(
                        modifier = Modifier
                            .fillMaxSize()
                            .background(Color.Black.copy(alpha = 0.3f)),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            imageVector = Icons.Default.PlayArrow,
                            contentDescription = "Video",
                            tint = Color.White,
                            modifier = Modifier.size(32.dp)
                        )
                    }
                }

                // Remove button
                IconButton(
                    onClick = { onRemove(attachment.id) },
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .padding(4.dp)
                        .size(24.dp)
                        .background(Color.Black.copy(alpha = 0.6f), CircleShape)
                ) {
                    Icon(
                        imageVector = Icons.Default.Close,
                        contentDescription = "Remove",
                        tint = Color.White,
                        modifier = Modifier.size(16.dp)
                    )
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
private fun BlossomMediaPickerSheet(
    onDismiss: () -> Unit,
    onSelect: (String) -> Unit,
    viewModel: ComposeNoteViewModel = hiltViewModel()
) {
    val context = LocalContext.current
    val colors = LocalNostrVaultColors.current
    var blossomMedia by remember { mutableStateOf<List<MediaItem>>(emptyList()) }
    var isLoading by remember { mutableStateOf(true) }

    LaunchedEffect(Unit) {
        withContext(Dispatchers.IO) {
            try {
                // Load blossom media from local relay
                val items = viewModel.loadBlossomMediaItems()
                withContext(Dispatchers.Main) {
                    blossomMedia = items
                    isLoading = false
                }
            } catch (e: Exception) {
                Log.e("BlossomPicker", "Failed to load media", e)
                withContext(Dispatchers.Main) {
                    isLoading = false
                }
            }
        }
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = WindowBackground
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp)
        ) {
            Text(
                text = "Pick from Blossom",
                fontSize = 20.sp,
                fontWeight = FontWeight.Bold,
                color = PrimaryText,
                modifier = Modifier.padding(bottom = 16.dp)
            )

            if (isLoading) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(200.dp),
                    contentAlignment = Alignment.Center
                ) {
                    CircularProgressIndicator(color = colors.primary)
                }
            } else if (blossomMedia.isEmpty()) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(200.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        text = "No media on Blossom",
                        color = SecondaryText,
                        fontSize = 14.sp
                    )
                }
            } else {
                LazyVerticalGrid(
                    columns = GridCells.Fixed(3),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                    modifier = Modifier.heightIn(max = 400.dp)
                ) {
                    items(blossomMedia) { item ->
                        Box(
                            modifier = Modifier
                                .aspectRatio(1f)
                                .clip(RoundedCornerShape(8.dp))
                                .combinedClickable(
                                    onClick = { onSelect(item.url) },
                                    onLongClick = {
                                        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                                        clipboard.setPrimaryClip(ClipData.newPlainText("Blossom URL", item.url))
                                        Toast.makeText(context, "Link copied", Toast.LENGTH_SHORT).show()
                                    }
                                )
                        ) {
                            AsyncImage(
                                model = item.url,
                                contentDescription = null,
                                modifier = Modifier.fillMaxSize(),
                                contentScale = ContentScale.Crop
                            )

                            if (item.type == MediaType.VIDEO) {
                                Icon(
                                    imageVector = Icons.Default.PlayArrow,
                                    contentDescription = "Video",
                                    tint = Color.White,
                                    modifier = Modifier
                                        .align(Alignment.Center)
                                        .size(32.dp)
                                )
                            }
                        }
                    }
                }
            }

            Spacer(Modifier.height(16.dp))
        }
    }
}
