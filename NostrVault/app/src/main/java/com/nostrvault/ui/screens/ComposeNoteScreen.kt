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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
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
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.style.TextOverflow
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
import com.nostrvault.service.BlobDescriptor
import com.nostrvault.service.BlossomService
import com.nostrvault.service.DraftService
import com.nostrvault.service.FeedService
import com.nostrvault.service.MediaItem
import com.nostrvault.service.MediaType
import com.nostrvault.service.NostrService
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.PendingPostManager
import com.nostrvault.service.StatsService
import com.nostrvault.ui.components.AccountInfo
import com.nostrvault.ui.components.AccountSwitcherSheet
import com.nostrvault.ui.components.buildAccountInfos
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.components.NostrMentions
import com.nostrvault.ui.components.QuotedNoteCard
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
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
    private val statsService: StatsService,
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

    /** All accounts (owner + added) with resolved name/avatar, for the in-composer switcher. */
    val accounts: StateFlow<List<AccountInfo>> =
        combine(configStore.config, nostrService.profiles) { config, profiles ->
            buildAccountInfos(config, profiles, includeWhitelisted = false)
        }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    /** The currently active account (for the composer avatar). */
    val activeAccount: StateFlow<AccountInfo?> =
        accounts.map { list -> list.firstOrNull { it.isActive } }
            .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    fun switchAccount(npub: String) {
        viewModelScope.launch { configStore.switchActiveAccount(npub) }
    }

    private val _showBlossomPicker = MutableStateFlow(false)
    val showBlossomPicker = _showBlossomPicker.asStateFlow()

    // @mention autocomplete state
    private val _mentionResults = MutableStateFlow<List<FeedProfile>>(emptyList())
    val mentionResults = _mentionResults.asStateFlow()

    /** Char offsets of the active `@query` token in `content` (start = the `@`). */
    private var mentionStartOffset: Int? = null
    private var mentionEndOffset: Int? = null

    /** The query of the mention currently being edited, and its debounced relay search. */
    private var currentMentionQuery: String? = null
    private var mentionSearchJob: Job? = null

    /**
     * Maps an inserted display token (e.g. "@Alice") → hex pubkey. The editor shows
     * `@name` for readability; tokens are converted back to `nostr:npub…` at publish
     * and draft-save time so published notes stay interoperable.
     */
    private val mentionMap = mutableMapOf<String, String>()

    val isReply: Boolean get() = replyToNoteId != null
    val isQuote: Boolean get() = quoteToNoteId != null

    /**
     * Whether this composer was opened to resume an existing draft. When true the
     * draft-picker badge is hidden (matching iOS, which only offers the picker on a
     * fresh compose, not while editing a draft).
     */
    val isEditingExistingDraft: Boolean get() = resumeDraftId != null

    /** All saved drafts for the active account, backing the in-composer picker. */
    val drafts: StateFlow<List<Draft>> = draftService.drafts


    init {
        // Start waking sleeping mirror hosts (e.g. the Mac relay) now, so
        // they're reachable by the time the user hits Post.
        blossomService.prewarmMirrors()

        // Restore content from a resumed draft
        if (resumeDraftId != null) {
            val draft = draftService.findDraft(resumeDraftId)
            if (draft != null) {
                _content.value = convertNostrToMentions(draft.content)
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
            // nostr: reference is appended to content at publish time, not pre-populated
        }
    }

    fun setContent(text: String) {
        _content.value = text
        scheduleDraftSave()
    }

    /**
     * Called on every text edit with the new text and the caret offset. Updates
     * the draft and recomputes the @mention query at the caret (which may be
     * anywhere in the text, not just at the end).
     */
    fun onContentChanged(text: String, caret: Int) {
        _content.value = text
        scheduleDraftSave()
        updateMentionQuery(text, caret)
    }

    /**
     * Finds the @query at the caret and populates [mentionResults]. Scans backwards
     * from the caret to the `@` that begins the token currently being edited, so
     * mentions work mid-message and not only at the end.
     */
    private fun updateMentionQuery(text: String, caret: Int) {
        val safeCaret = caret.coerceIn(0, text.length)

        var atIndex = -1
        var i = safeCaret
        while (i > 0) {
            val ch = text[i - 1]
            if (ch == '@') { atIndex = i - 1; break }
            // A mention token can't contain whitespace/newline.
            if (ch == ' ' || ch == '\n' || ch == '\t') break
            i--
        }

        if (atIndex < 0) { clearMention(); return }

        // The `@` must start a word (preceded by start-of-text or whitespace) so
        // email addresses like foo@bar.com don't trigger the picker.
        if (atIndex > 0) {
            val before = text[atIndex - 1]
            if (before != ' ' && before != '\n' && before != '\t') { clearMention(); return }
        }

        val query = text.substring(atIndex + 1, safeCaret)
        mentionStartOffset = atIndex
        mentionEndOffset = safeCaret
        currentMentionQuery = query
        filterMentionResults(query)
        searchMentionProfiles(query)
    }

    private fun filterMentionResults(query: String) {
        val profilesMap = nostrService.profiles.value
        val followed = feedService.followedPubkeys.value
        val self = nostrService.activeHexPubkey

        // Thread participants are valid mention targets when replying, even if
        // you don't follow them.
        val parent = replyToNoteId?.let { feedService.findNote(it) }
        val threadPubkeys = LinkedHashSet<String>()
        if (parent != null) {
            threadPubkeys.add(parent.pubkey)
            parent.tags.filter { it.size >= 2 && it[0] == "p" }.forEach { threadPubkeys.add(it[1]) }
        }
        threadPubkeys.remove(self)

        val results: List<FeedProfile> = if (query.isEmpty()) {
            // Just typed `@`: thread participants first, then followed.
            val threadProfiles = threadPubkeys.mapNotNull { profilesMap[it] }
            val followedProfiles = followed.asSequence()
                .filter { it != self }
                .mapNotNull { profilesMap[it] }
                .filter { p -> threadProfiles.none { it.pubkey == p.pubkey } }
            (threadProfiles + followedProfiles).take(8)
        } else {
            // Search the entire profile cache (feed authors, search results, etc.),
            // not just follows, ranking thread participants and follows first.
            val lower = query.lowercase()
            val followedSet = followed.toHashSet()
            profilesMap.values.asSequence()
                .filter { it.pubkey != self }
                .filter { p ->
                    p.bestName.lowercase().contains(lower) ||
                        (p.name?.lowercase()?.contains(lower) == true) ||
                        (p.displayName?.lowercase()?.contains(lower) == true) ||
                        (p.nip05?.lowercase()?.contains(lower) == true)
                }
                .sortedWith(
                    compareByDescending<FeedProfile> { threadPubkeys.contains(it.pubkey) }
                        .thenByDescending { followedSet.contains(it.pubkey) }
                        .thenByDescending { it.bestName.lowercase().startsWith(lower) }
                        .thenBy { it.bestName.length }
                )
                .take(8)
                .toList()
        }

        _mentionResults.value = results
    }

    /**
     * Debounced NIP-50 relay search so you can @-mention people who aren't followed
     * and whose profile isn't cached yet. Discovered profiles are merged into the
     * cache by [NostrService.globalSearch]; we re-filter when results arrive.
     */
    private fun searchMentionProfiles(query: String) {
        mentionSearchJob?.cancel()
        if (query.length < 2) return
        mentionSearchJob = viewModelScope.launch {
            delay(350)
            nostrService.globalSearch(query) {
                if (currentMentionQuery == query) {
                    filterMentionResults(query)
                }
            }
        }
    }

    /**
     * Replaces the active `@query` token (which may be mid-text) with a readable
     * `@name` display token and returns the new (text, caret) for the UI to apply.
     * The token is converted back to `nostr:npub…` at publish/draft-save time.
     */
    fun insertMention(profile: FeedProfile): Pair<String, Int>? {
        val token = mentionToken(profile.bestName, profile.pubkey)
        val replacement = "$token "
        val text = _content.value
        val start = mentionStartOffset
        val end = mentionEndOffset

        val newText: String
        val newCaret: Int
        if (start != null && end != null && start <= end && end <= text.length) {
            newText = text.substring(0, start) + replacement + text.substring(end)
            newCaret = start + replacement.length
        } else {
            // Fallback: append at the end.
            newText = if (text.isEmpty() || text.endsWith(" ") || text.endsWith("\n")) {
                text + replacement
            } else {
                "$text $replacement"
            }
            newCaret = newText.length
        }

        mentionMap[token] = profile.pubkey
        _content.value = newText
        scheduleDraftSave()
        clearMention()
        return newText to newCaret
    }

    private fun clearMention() {
        mentionStartOffset = null
        mentionEndOffset = null
        currentMentionQuery = null
        mentionSearchJob?.cancel()
        _mentionResults.value = emptyList()
    }

    /** Display token shown in the editor for a mention (e.g. "@Alice"). */
    private fun mentionToken(name: String, pubkey: String): String {
        val clean = name.replace('\n', ' ').trim()
        return "@" + clean.ifEmpty { pubkey.take(8) }
    }

    /**
     * Converts `nostr:npub1…`/`nostr:nprofile1…` references to readable `@name`
     * tokens for editing, rebuilding [mentionMap]. Used when restoring a draft.
     */
    private fun convertNostrToMentions(text: String): String {
        val profilesMap = nostrService.profiles.value
        return NostrMentions.MENTION_REGEX.replace(text) { match ->
            val pubkey = NostrMentions.resolvePubkey(match.groupValues[1]) ?: return@replace match.value
            val token = mentionToken(profilesMap[pubkey]?.bestName ?: "", pubkey)
            mentionMap[token] = pubkey
            token
        }
    }

    /**
     * Converts `@name` display tokens back to canonical `nostr:npub…` references for
     * publishing and draft persistence. Longest tokens first so a shorter name that is
     * a prefix of another doesn't clobber it; a trailing word-boundary guards against
     * partial matches inside other words.
     */
    private fun convertMentionsToNostr(text: String): String {
        if (mentionMap.isEmpty()) return text
        var result = text
        for ((token, pubkey) in mentionMap.entries.sortedByDescending { it.key.length }) {
            val npub = nostrService.hexToNpub(pubkey) ?: continue
            val pattern = Regex(Regex.escape(token) + """(?![\p{L}\p{N}_])""")
            result = pattern.replace(result) { "nostr:$npub" }
        }
        return result
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
            val pubkey = nostrService.ownerHexPubkey
            val localBase = blossomService.localBlossomURL()
            // Prefer an external mirror so the inserted URL is publicly accessible in published notes
            val externalBase = config.activeBlossomMirrors
                .firstOrNull { url -> !url.contains("localhost") && !url.contains("127.0.0.1") }

            // Dedupe across local files, the local relay, and external mirrors by sha256.
            val items = linkedMapOf<String, MediaItem>()

            fun mediaTypeFor(mime: String?, url: String?): MediaType {
                val m = mime?.lowercase()
                when {
                    m != null && m.startsWith("image/") -> return MediaType.IMAGE
                    m != null && m.startsWith("video/") -> return MediaType.VIDEO
                    m != null && m.startsWith("audio/") -> return MediaType.AUDIO
                }
                return when (url?.substringAfterLast('.', "")?.lowercase()) {
                    "jpg", "jpeg", "png", "gif", "webp" -> MediaType.IMAGE
                    "mp4", "mov", "webm", "avi" -> MediaType.VIDEO
                    "mp3", "m4a", "wav", "ogg" -> MediaType.AUDIO
                    else -> MediaType.UNKNOWN
                }
            }

            fun addItem(sha256: String, type: MediaType, fallbackUrl: String?) {
                if (sha256.length != 64 || !sha256.all { it in "0123456789abcdef" }) return
                if (type == MediaType.UNKNOWN) return
                if (items.containsKey(sha256)) return
                // Use external mirror URL (BUD-01: {server}/{sha256}) so links work in published notes;
                // fall back to the blob's own URL, then the local relay.
                val insertUrl = when {
                    externalBase != null -> "$externalBase/$sha256"
                    fallbackUrl != null -> fallbackUrl
                    localBase != null -> "$localBase/$sha256"
                    else -> return
                }
                items[sha256] = MediaItem(
                    url = insertUrl,
                    type = type,
                    pubkey = pubkey,
                    tags = null,
                    mimeType = null
                )
            }

            // 1. Files cached in the local relay's blossom directory.
            val blossomDir = config.relayDataDir?.let { File(it, config.blossomPath) }
            if (blossomDir != null && blossomDir.exists()) {
                blossomDir.listFiles()?.forEach { file ->
                    if (!file.isFile) return@forEach
                    val filename = file.name
                    if (filename.startsWith(".") || filename == "LOCK") return@forEach
                    addItem(file.nameWithoutExtension, mediaTypeFor(null, filename), localBase?.let { "$it/$filename" })
                }
            }

            // 2. The local relay + external mirrors via the Blossom /list/<pubkey> endpoint,
            //    so media that lives only on a mirror still appears in the picker.
            if (pubkey.isNotEmpty()) {
                val sources = buildList {
                    add(null) // local relay (default nostrURL base)
                    addAll(config.activeBlossomMirrors)
                }
                val blobLists = coroutineScope {
                    sources.map { base ->
                        async {
                            try {
                                if (base == null) statsService.fetchBlobList(pubkey)
                                else statsService.fetchBlobList(pubkey, base)
                            } catch (e: Exception) {
                                emptyList<BlobDescriptor>()
                            }
                        }
                    }.awaitAll()
                }
                blobLists.flatten().forEach { blob ->
                    val sha = blob.sha256 ?: return@forEach
                    addItem(sha, mediaTypeFor(blob.type, blob.url), blob.url)
                }
            }

            items.values.sortedByDescending { it.url }
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
                        content = convertMentionsToNostr(text),
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
                // Convert `@name` display tokens back to canonical `nostr:npub…` references.
                var finalContent = convertMentionsToNostr(text)
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
                    val relayHint = configStore.config.value.nostrURL ?: ""
                    val quotedPubkey = feedService.findNote(quoteToNoteId)?.pubkey ?: ""
                    tags.add(listOf("q", quoteToNoteId, relayHint, quotedPubkey))
                    if (quotedPubkey.isNotEmpty() && tags.none { it.size >= 2 && it[0] == "p" && it[1] == quotedPubkey }) {
                        tags.add(listOf("p", quotedPubkey))
                    }
                    val note1 = HavenBridge.hexToNote1(quoteToNoteId)
                    if (note1 != null) finalContent += "\nnostr:$note1"
                }

                // 2b. Add p-tags for inline @mentions (nostr:npub/nprofile refs).
                tags.addAll(extractMentionPTags(finalContent, tags))

                // 3. Sign and publish
                val event = nostrService.signEventAsync(kind = 1, content = finalContent, tags = tags)
                if (event != null) {
                    // Optimistic insert: inject the note immediately so the thread
                    // view shows it before relay confirmation (mirrors iOS behavior).
                    feedService.emitOptimisticNote(
                        FeedNote.fromEvent(
                            id = event.id,
                            pubkey = event.pubkey,
                            content = finalContent,
                            tags = tags,
                            createdAt = event.createdAt,
                            kind = 1,
                        )
                    )
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

        // NIP-10/NIP-01: addressable-event a-tags, alongside the e-tags above. A
        // parameterized replaceable event (kind 30000–39999, e.g. a long-form article)
        // gets a new event id every time it's edited, so an e-tag-only reply silently
        // becomes orphaned from other clients' view of the thread once the author edits
        // it — the "a" coordinate (kind:pubkey:d-tag) is what stays stable across edits.
        fun addressableCoordinate(kind: Int, pubkey: String, noteTags: List<List<String>>): String? {
            if (kind < 30000 || kind >= 40000) return null
            val dTag = noteTags.firstOrNull { it.size >= 2 && it[0] == "d" }?.get(1) ?: return null
            return "$kind:$pubkey:$dTag"
        }
        val parentNonMentionATags = parentNote.tags.filter { it.size >= 2 && it[0] == "a" }
            .filter { it.size < 4 || it[3] != "mention" }

        if (parentNonMentionETags.isEmpty()) {
            // Parent IS the root note — single e-tag with "root" marker. NIP-10: the
            // optional 5th element is the event author's pubkey, used by the outbox
            // model to know whose relays to fetch it from.
            tags.add(listOf("e", parentId, "", "root", parentNote.pubkey))
            addressableCoordinate(parentNote.kind, parentNote.pubkey, parentNote.tags)?.let { coord ->
                tags.add(listOf("a", coord, "", "root"))
            }
        } else {
            // Parent is itself a reply — find the thread root
            val rootTag = parentNonMentionETags.firstOrNull { it.size >= 4 && it[3] == "root" }
            val threadRootId = rootTag?.get(1) ?: parentNonMentionETags[0][1]
            val threadRootSource = rootTag ?: parentNonMentionETags[0]
            val threadRootPubkey = if (threadRootSource.size >= 5) threadRootSource[4] else null
            tags.add(
                if (threadRootPubkey != null) listOf("e", threadRootId, "", "root", threadRootPubkey)
                else listOf("e", threadRootId, "", "root")
            )
            tags.add(listOf("e", parentId, "", "reply", parentNote.pubkey))

            // Root a-tag: we only have the root's event id here (not its kind/pubkey/
            // d-tag), so propagate it forward from the parent's own root a-tag if it had one.
            val rootATag = parentNonMentionATags.firstOrNull { it.size >= 4 && it[3] == "root" }
                ?: parentNonMentionATags.firstOrNull()
            rootATag?.let { tags.add(listOf("a", it[1], "", "root")) }

            // Reply a-tag: the immediate parent might itself be addressable.
            addressableCoordinate(parentNote.kind, parentNote.pubkey, parentNote.tags)?.let { coord ->
                tags.add(listOf("a", coord, "", "reply"))
            }
        }

        // Always tag the parent author
        tags.add(listOf("p", parentNote.pubkey))

        // NIP-10: "the reply event's p tags should contain all of E's p tags as well
        // as the pubkey of the event being replied to" — otherwise everyone else in
        // the thread except the immediate parent silently stops being notified.
        val seenPubkeys = mutableSetOf(parentNote.pubkey)
        for (tag in parentNote.tags) {
            if (tag.size >= 2 && tag[0] == "p" && seenPubkeys.add(tag[1])) {
                tags.add(listOf("p", tag[1]))
            }
        }

        return tags
    }

    /**
     * Extracts hex pubkeys from `nostr:npub1.../nostr:nprofile1...` references in
     * [text] and returns new `["p", hex]` tags, skipping pubkeys already present in
     * [existing].
     */
    private fun extractMentionPTags(text: String, existing: List<List<String>>): List<List<String>> {
        val seen = existing.filter { it.size >= 2 && it[0] == "p" }
            .map { it[1] }
            .toMutableSet()
        val result = mutableListOf<List<String>>()
        for (match in NostrMentions.MENTION_REGEX.findAll(text)) {
            val pubkey = NostrMentions.resolvePubkey(match.groupValues[1]) ?: continue
            if (seen.add(pubkey)) result.add(listOf("p", pubkey))
        }
        return result
    }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun ComposeNoteScreen(
    replyToNoteId: String? = null,
    onPublished: () -> Unit,
    onBack: () -> Unit,
    onOpenDrafts: () -> Unit = {},
    viewModel: ComposeNoteViewModel = hiltViewModel(),
) {
    val content by viewModel.content.collectAsState()
    val drafts by viewModel.drafts.collectAsState()
    val isPublishing by viewModel.isPublishing.collectAsState()
    val isUploading by viewModel.isUploading.collectAsState()
    val uploadMessage by viewModel.uploadMessage.collectAsState()
    val error by viewModel.error.collectAsState()
    val replyingToName by viewModel.replyingToName.collectAsState()
    val quotedNote by viewModel.quotedNote.collectAsState()
    val quotedProfile by viewModel.quotedProfile.collectAsState()
    val attachments by viewModel.attachments.collectAsState()
    val showBlossomPicker by viewModel.showBlossomPicker.collectAsState()
    val mentionResults by viewModel.mentionResults.collectAsState()
    val accounts by viewModel.accounts.collectAsState()
    val activeAccount by viewModel.activeAccount.collectAsState()
    var showAccountSwitcher by remember { mutableStateOf(false) }
    val colors = LocalNostrVaultColors.current
    val context = LocalContext.current

    // Local editing state with cursor tracking (drives @mention detection). Kept in
    // sync when the ViewModel changes `content` externally (draft restore, media insert).
    var textFieldValue by remember { mutableStateOf(TextFieldValue(content)) }
    LaunchedEffect(content) {
        if (content != textFieldValue.text) {
            textFieldValue = TextFieldValue(content, TextRange(content.length))
        }
    }

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
                    // Draft picker badge (mirrors iOS ComposeView): shown only on a fresh
                    // compose when drafts exist, not while editing an existing draft.
                    if (drafts.isNotEmpty() && !viewModel.isEditingExistingDraft) {
                        Surface(
                            onClick = onOpenDrafts,
                            shape = CircleShape,
                            color = colors.primary.copy(alpha = 0.12f),
                            contentColor = colors.primary,
                            modifier = Modifier.padding(end = 4.dp),
                        ) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
                            ) {
                                Icon(
                                    imageVector = Icons.Default.Description,
                                    contentDescription = "Drafts",
                                    modifier = Modifier.size(14.dp),
                                )
                                Spacer(Modifier.width(4.dp))
                                Text(
                                    text = "${drafts.size}",
                                    fontSize = 12.sp,
                                    fontWeight = FontWeight.Bold,
                                )
                            }
                        }
                    }
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
                                text = "Post",
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
            // Posting-as account avatar + quick switch (mirrors iOS ComposeView:
            // long-press the avatar to switch the posting account)
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .combinedClickable(
                        onClick = {},
                        onLongClick = { showAccountSwitcher = true },
                    )
                    .padding(bottom = 12.dp),
            ) {
                AvatarImage(
                    url = activeAccount?.avatarUrl,
                    pubkey = activeAccount?.hexPubkey ?: "",
                    size = 32.dp,
                    displayName = activeAccount?.displayName,
                )
                Spacer(Modifier.width(8.dp))
                Column {
                    Text("Posting as", color = SecondaryText, fontSize = 11.sp)
                    Text(
                        text = activeAccount?.displayName ?: "Owner",
                        color = PrimaryText,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
                if (accounts.size > 1) {
                    Spacer(Modifier.width(4.dp))
                    Icon(
                        imageVector = Icons.Filled.UnfoldMore,
                        contentDescription = "Switch account",
                        tint = SecondaryText,
                        modifier = Modifier.size(18.dp),
                    )
                }
            }

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
                value = textFieldValue,
                onValueChange = { newValue ->
                    textFieldValue = newValue
                    viewModel.onContentChanged(newValue.text, newValue.selection.start)
                },
                placeholder = {
                    Text(
                        when {
                            viewModel.isReply -> "Write your reply..."
                            viewModel.isQuote -> "Add your thoughts..."
                            else -> "What's happening?"
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

            // @mention suggestions
            if (mentionResults.isNotEmpty()) {
                MentionSuggestions(
                    results = mentionResults,
                    onSelect = { profile ->
                        viewModel.insertMention(profile)?.let { (newText, caret) ->
                            textFieldValue = TextFieldValue(newText, TextRange(caret))
                        }
                    },
                )
            }

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
                        imageVector = NostrVaultIcons.Blossom,
                        contentDescription = "Pick from Blossom",
                        tint = colors.primary,
                        modifier = Modifier.size(20.dp)
                    )
                }
            }

        }
    }

    // Blossom media picker sheet
    if (showBlossomPicker) {
        BlossomMediaPickerSheet(
            onDismiss = { viewModel.setShowBlossomPicker(false) },
            onSelect = { url -> viewModel.addBlossomMedia(url) }
        )
    }

    // In-composer account quick-switch
    if (showAccountSwitcher) {
        AccountSwitcherSheet(
            accounts = accounts,
            onSelectAccount = { npub ->
                viewModel.switchAccount(npub)
                showAccountSwitcher = false
            },
            onDismiss = { showAccountSwitcher = false },
        )
    }
}

/** Dropdown list of profiles matching the active `@query`, shown under the editor. */
@Composable
private fun MentionSuggestions(
    results: List<FeedProfile>,
    onSelect: (FeedProfile) -> Unit,
) {
    Surface(
        color = Color(0xFF22222A),
        shape = RoundedCornerShape(12.dp),
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 4.dp)
            .heightIn(max = 264.dp),
    ) {
        Column(modifier = Modifier.verticalScroll(rememberScrollState())) {
            results.forEach { profile ->
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { onSelect(profile) }
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                ) {
                    AvatarImage(
                        url = profile.pictureURL,
                        pubkey = profile.pubkey,
                        size = 36.dp,
                        displayName = profile.bestName,
                    )
                    Spacer(Modifier.width(10.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = profile.bestName,
                            color = PrimaryText,
                            fontSize = 15.sp,
                            fontWeight = FontWeight.Medium,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        profile.nip05?.takeIf { it.isNotBlank() }?.let { nip05 ->
                            Text(
                                text = nip05.removePrefix("_@"),
                                color = TertiaryText,
                                fontSize = 12.sp,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                }
            }
        }
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
