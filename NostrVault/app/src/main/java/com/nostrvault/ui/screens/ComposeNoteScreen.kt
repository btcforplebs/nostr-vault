package com.nostrvault.ui.screens

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.util.Log
import android.widget.Toast
import androidx.activity.compose.BackHandler
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
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
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
import com.nostrvault.data.model.MediaUploadOutcomeMessage
import com.nostrvault.data.model.NIP10Thread
import com.nostrvault.data.model.NoteTagging
import com.nostrvault.data.model.PostingAccount
import com.nostrvault.data.model.QueuedMediaPost
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.service.BlossomService
import com.nostrvault.service.DraftService
import com.nostrvault.service.FeedService
import com.nostrvault.service.MediaPostQueue
import com.nostrvault.service.MediaPrivacy
import com.nostrvault.service.NostrService
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.PendingPostManager
import com.nostrvault.ui.components.AccountInfo
import com.nostrvault.ui.components.AccountSwitcherSheet
import com.nostrvault.ui.components.buildAccountInfos
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.components.NostrMentions
import com.nostrvault.ui.components.QuotedNoteCard
import com.nostrvault.ui.notification.ErrorStyle
import com.nostrvault.ui.notification.NotificationManager
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
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
    /**
     * NIP-92 `alt` — what this media is, for anyone who cannot see it.
     * Published inside the attachment's `imeta` tag; blank means omitted.
     */
    val altText: String = "",
    /**
     * Set when the media is already on a Blossom server (picked from the
     * relay picker): posting publishes this URL as-is instead of uploading.
     */
    val hostedUrl: String? = null,
    /** The hosted blob's hash, for its `imeta x`. */
    val sha256: String? = null,
    /** A local copy of the hosted blob, measured for `imeta dim`. */
    val localFile: File? = null,
    /** The hosted blob's size, for `imeta size`. */
    val byteCount: Long? = null,
)

/**
 * A full MIME type for a blob, from the server's `type` when that is one,
 * else from the file extension; null when neither says. Local blobs are only
 * classed as "image"/"video", which is not a MIME type and must not reach
 * `imeta m`.
 */
internal fun blobMimeType(serverType: String?, name: String?): String? {
    if (serverType != null && '/' in serverType && !serverType.endsWith("/*")) return serverType
    return when (name?.substringBefore('?')?.substringAfterLast('.', "")?.lowercase()) {
        "jpg", "jpeg" -> "image/jpeg"
        "png" -> "image/png"
        "gif" -> "image/gif"
        "webp" -> "image/webp"
        "avif" -> "image/avif"
        "mp4", "m4v" -> "video/mp4"
        "mov" -> "video/quicktime"
        "webm" -> "video/webm"
        else -> null
    }
}

/**
 * How many attachments one note carries. The editor's row, the upload progress
 * copy and every reader's media layout assume a small number.
 */
const val MAX_ATTACHMENTS = 4

/**
 * What to ask `PickMultipleVisualMedia` for when [attachmentCount] are already
 * attached.
 *
 * The contract rejects `maxItems <= 1` at construction ("Max items must be
 * higher than 1") and the composable rebuilds it on every recomposition, so
 * handing it the literal number of free slots threw as soon as only one was
 * left. Two is the floor; [ComposeNoteViewModel.addAttachments] discards
 * anything over the real cap.
 */
internal fun pickerMaxItems(attachmentCount: Int): Int =
    maxOf(2, MAX_ATTACHMENTS - attachmentCount)

@HiltViewModel
class ComposeNoteViewModel @Inject constructor(
    private val nostrService: NostrService,
    private val feedService: FeedService,
    private val pendingPostManager: PendingPostManager,
    private val draftService: DraftService,
    private val blossomService: BlossomService,
    private val configStore: ConfigStore,
    private val mediaPostQueue: MediaPostQueue,
    private val notificationManager: NotificationManager,
    private val blossomPickerMedia: BlossomPickerMedia,
    @ApplicationContext private val context: Context,
    savedStateHandle: SavedStateHandle,
) : ViewModel() {

    private val replyToNoteId: String? = savedStateHandle["replyTo"]
    private val quoteToNoteId: String? = savedStateHandle["quoteTo"]
    private val resumeDraftId: String? = savedStateHandle["draftId"]
    /** Text to start with, e.g. a song shared from the music player. */
    private val initialText: String? = savedStateHandle["text"]

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
     * The note this quote cites. Resolved through [FeedService.quoteTarget] so
     * quoting a repost cites the original's id and author, not the reposter.
     */
    private fun quoteTarget(): FeedNote? = quoteToNoteId?.let { feedService.quoteTarget(it) }

    /** The event id the quote cites (also what a draft stores). */
    private fun quoteCitedId(): String? = quoteTarget()?.id ?: quoteToNoteId

    /**
     * Whether this composer was opened to resume an existing draft. When true the
     * draft-picker badge is hidden (matching iOS, which only offers the picker on a
     * fresh compose, not while editing a draft).
     */
    val isEditingExistingDraft: Boolean get() = resumeDraftId != null

    /** All saved drafts for the active account, backing the in-composer picker. */
    val drafts: StateFlow<List<Draft>> = draftService.drafts


    init {
        initialText?.takeIf { it.isNotBlank() }?.let { _content.value = it }
        // Start waking sleeping mirror hosts (e.g. the Mac relay) now, so
        // they're reachable by the time the user hits Post.
        blossomService.prewarmMirrors()
        // Drafts saved on another device show in the picker (iOS: ComposeView.onAppear).
        draftService.refreshFromRelay()

        // Restore content from a resumed draft
        if (resumeDraftId != null) {
            val draft = draftService.findDraft(resumeDraftId)
            if (draft != null) {
                _content.value = convertNostrToMentions(draft.content)
            }
        }

        if (replyToNoteId != null) {
            // Replying to a repost answers the note it carries, and its author.
            val parentNote = feedService.quoteTarget(replyToNoteId)
            if (parentNote != null) {
                val profile = nostrService.profiles.value[parentNote.pubkey]
                _replyingToName.value = profile?.bestName ?: parentNote.pubkey.take(8) + "..."
            }
        }
        if (quoteToNoteId != null) {
            val quoted = quoteTarget()
            showQuoted(quoted)
            // A bare repost carries only the original's id and author: fetch the
            // original so the preview can show its text.
            if (quoted != null && quoted.content.isEmpty()) {
                feedService.fetchMissingNote(quoted.id)
                viewModelScope.launch {
                    feedService.parentNotesCache.first { cache ->
                        cache[quoted.id]?.let { it.id == quoted.id && it.kind != 6 } == true
                    }
                    showQuoted(quoteTarget())
                }
            }
            // nostr: reference is appended to content at publish time, not pre-populated
        }
    }

    private fun showQuoted(quoted: FeedNote?) {
        _quotedNote.value = quoted
        _quotedProfile.value = quoted?.let { nostrService.profiles.value[it.pubkey] }
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
            // not just follows, ranking thread participants, follows, then the
            // rest of the Web of Trust first.
            val lower = query.lowercase()
            val followedSet = followed.toHashSet()
            val wotSet = feedService.webOfTrustForRanking()
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
                        .thenByDescending { wotSet.contains(it.pubkey) }
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
            nostrService.globalSearch(query, NostrService.SearchCaller.MENTION) {
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

    /**
     * Adds as many of [uris] as still fit.
     *
     * The old guard compared the *existing* count against the cap once per
     * picked item, so it never saw the ones it had just accepted — picking four
     * while three were attached produced seven. The picker's own `maxItems` is
     * no help either: it has to be at least 2 or it throws, so the cap is
     * enforced here, on the result.
     */
    fun addAttachments(uris: List<Uri>) {
        val room = MAX_ATTACHMENTS - _attachments.value.size
        if (room <= 0) {
            _error.value = "A note can carry $MAX_ATTACHMENTS attachments."
            return
        }
        val newAttachments = uris.take(room).map { uri ->
            val mimeType = context.contentResolver.getType(uri) ?: "application/octet-stream"
            val isVideo = mimeType.startsWith("video/")
            Attachment(uri = uri, mimeType = mimeType, isVideo = isVideo)
        }
        if (uris.size > room) {
            _error.value = "A note can carry $MAX_ATTACHMENTS attachments."
        }
        _attachments.value = _attachments.value + newAttachments
    }

    /** "Save to my Blossom" in the GIF picker (iOS saveGifsToBlossom). */
    val saveGifsToBlossom: StateFlow<Boolean> = configStore.config
        .map { it.saveGifsToBlossom }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), configStore.config.value.saveGifsToBlossom)

    fun setSaveGifsToBlossom(on: Boolean) {
        configStore.update { it.copy(saveGifsToBlossom = on) }
    }

    /** A picked GIF is downloading: one at a time, and Post waits for it (iOS isFetchingGif). */
    private val _isFetchingGif = MutableStateFlow(false)
    val isFetchingGif: StateFlow<Boolean> = _isFetchingGif.asStateFlow()

    /**
     * A picked nostr.build GIF: its link goes into the text, or with "Save to
     * my Blossom" on it is downloaded and attached, so posting uploads it to
     * your own Blossom servers like any photo. iOS: ComposeView.attachGif.
     */
    fun pickGif(gif: com.nostrvault.data.gif.NostrBuildGif) {
        if (!saveGifsToBlossom.value) {
            val text = _content.value
            val sep = if (text.isEmpty() || text.endsWith("\n") || text.endsWith(" ")) "" else "\n"
            setContent(text + sep + gif.url)
            return
        }
        if (_attachments.value.size >= MAX_ATTACHMENTS) {
            _error.value = "A note can carry $MAX_ATTACHMENTS attachments."
            return
        }
        if (_isFetchingGif.value) return
        _isFetchingGif.value = true
        viewModelScope.launch {
            try {
                val (bytes, mime) = com.nostrvault.data.gif.NostrBuildGifs.download(gif.url)
                val ext = if (mime == "image/webp") "webp" else "gif"
                val file = withContext(Dispatchers.IO) {
                    File(context.cacheDir, "gif-${java.util.UUID.randomUUID()}.$ext").apply { writeBytes(bytes) }
                }
                if (_attachments.value.size < MAX_ATTACHMENTS) {
                    _attachments.value = _attachments.value + Attachment(uri = Uri.fromFile(file), mimeType = mime)
                }
            } catch (e: Exception) {
                _error.value = "Could not fetch GIF: ${e.message ?: "unknown error"}"
            } finally {
                _isFetchingGif.value = false
            }
        }
    }

    /** Stores the NIP-92 description the author wrote for one attachment. */
    fun setAttachmentAlt(id: String, alt: String) {
        _attachments.value = _attachments.value.map {
            if (it.id == id) it.copy(altText = alt) else it
        }
    }

    fun removeAttachment(id: String) {
        _attachments.value = _attachments.value.filter { it.id != id }
    }

    fun setShowBlossomPicker(show: Boolean) {
        _showBlossomPicker.value = show
    }

    /**
     * Attaches media picked from the relay picker. It shows in the attachment
     * strip like a fresh upload; posting publishes its existing URL with an
     * `imeta` and does not upload it again.
     */
    fun addBlossomMedia(item: BlossomMediaItem) {
        _showBlossomPicker.value = false
        if (_attachments.value.any { it.sha256 == item.sha256 }) return
        if (_attachments.value.size >= MAX_ATTACHMENTS) {
            _error.value = "A note can carry $MAX_ATTACHMENTS attachments."
            return
        }
        val mime = blobMimeType(item.mimeType, item.localFile?.name ?: item.displayUrl)
        _attachments.value = _attachments.value + Attachment(
            uri = item.localFile?.let { Uri.fromFile(it) } ?: Uri.parse(item.displayUrl),
            mimeType = mime ?: if (item.isVideo) "video/*" else "image/*",
            isVideo = item.isVideo,
            hostedUrl = item.displayUrl,
            sha256 = item.sha256,
            localFile = item.localFile,
            byteCount = item.size,
        )
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

    /** The owner's media for the relay picker; see [BlossomPickerMedia]. */
    suspend fun loadBlossomMediaItems(): List<BlossomMediaItem> = blossomPickerMedia.load()

    /** Closing now should ask "Save this note as a draft?" (iOS handleCancelTapped). */
    fun shouldAskToSaveDraft(): Boolean = composeNeedsDraftPrompt(_content.value)

    /** "Save Draft": write the draft now rather than waiting on the debounce. */
    fun saveDraftNow() {
        autoSaveJob?.cancel()
        val text = _content.value
        if (text.isBlank()) return
        draftService.saveDraft(
            Draft(
                id = draftId,
                content = convertMentionsToNostr(text),
                replyToId = replyToNoteId,
                quoteId = quoteCitedId(),
            )
        )
    }

    /** "Discard": drop the pending autosave and any draft this session wrote or resumed. */
    fun discardDraft() {
        autoSaveJob?.cancel()
        draftService.deleteDraft(draftId)
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
                        quoteId = quoteCitedId(),
                    )
                )
            }
        }
    }

    fun publish(onPublished: () -> Unit) {
        if (_isFetchingGif.value) return
        val text = _content.value.trim()
        if (text.isBlank() && _attachments.value.isEmpty()) return

        // The account this note is for, locked now: the signer reads whichever
        // account is active when it signs, after the media upload, and the
        // account can change in between (see PostingAccount).
        val lock = nostrService.lockPostingAccount()

        viewModelScope.launch {
            _isPublishing.value = true
            _error.value = null
            try {
                // 1. Upload attachments first
                // Convert `@name` display tokens back to canonical `nostr:npub…` references.
                val baseContent = convertMentionsToNostr(text)
                var finalContent = baseContent
                // NIP-92 descriptors, filled in as each upload lands. Published
                // as `imeta` tags so a reader can reserve the right box before
                // the bytes arrive and can read out what the media is.
                var mediaDescriptors: List<NoteTagging.MediaDescriptor> = emptyList()
                // The same attachments in queue form. Any with a null url are
                // saved on this device only; the post then waits in
                // MediaPostQueue instead of being cancelled.
                var queuedMedia: List<QueuedMediaPost.Media> = emptyList()
                var unreachableServers: List<String> = emptyList()
                if (_attachments.value.isNotEmpty()) {
                    _isUploading.value = true
                    val result = uploadAttachments()
                    _isUploading.value = false

                    when (result) {
                        is AttachmentUploadResult.Failed -> {
                            _error.value = result.message
                            _isPublishing.value = false
                            return@launch
                        }
                        is AttachmentUploadResult.Done -> {
                            queuedMedia = result.media
                            unreachableServers = result.unreachableServers
                        }
                    }

                    if (queuedMedia.all { it.url != null }) {
                        mediaDescriptors = queuedMedia.map { it.descriptor() }
                        // Append media URLs to content
                        mediaDescriptors.forEach { media ->
                            finalContent += "\n${media.url}"
                        }
                    }
                }

                // 2. Build tags. A reply to a NIP-22 comment is itself a
                // comment (kind 1111); everything else stays kind 1.
                val (replyTags, eventKind) = buildReplyTags()
                val tags = replyTags.toMutableList()
                var quoteSuffix: String? = null
                val quotedId = quoteCitedId()
                if (quotedId != null) {
                    // No relay hint: this app's relay, embedded or external,
                    // only ever runs on this phone (see normalizeExternalRelayURL),
                    // and naming it would point every other client at itself.
                    val quotedPubkey = quoteTarget()?.pubkey ?: ""
                    tags.add(listOf("q", quotedId, "", quotedPubkey))
                    if (quotedPubkey.isNotEmpty() && tags.none { it.size >= 2 && it[0] == "p" && it[1] == quotedPubkey }) {
                        tags.add(listOf("p", quotedPubkey))
                    }
                    val note1 = HavenBridge.hexToNote1(quotedId)
                    if (note1 != null) {
                        quoteSuffix = "\nnostr:$note1"
                        finalContent += "\nnostr:$note1"
                    }
                }

                // Some media is only on this device: hand the post to the queue,
                // which sends it once an outside server takes the media. The
                // reply/quote/mention tags are kept; hashtags and imeta are
                // rebuilt from the final URLs by QueuedMediaPost.assembled(),
                // exactly as below.
                if (queuedMedia.any { it.url == null }) {
                    // Mentions read from the same text a direct post reads them
                    // from, minus the media lines (URLs carry no nostr: refs).
                    tags.addAll(extractMentionPTags(baseContent + (quoteSuffix ?: ""), tags))
                    val queued = QueuedMediaPost(
                        accountNpub = lock.npub,
                        body = baseContent,
                        media = queuedMedia,
                        quoteSuffix = quoteSuffix,
                        baseTags = tags,
                        kind = eventKind,
                    )
                    mediaPostQueue.enqueue(queued)
                    // The queue now holds the post on disk; a draft too would
                    // offer to post it a second time.
                    autoSaveJob?.cancel()
                    draftService.deleteDraft(draftId)
                    val macHost = configStore.config.value.macRelayHttpsURL
                        .takeIf { it.isNotEmpty() }?.let { hostOf(it) }
                    notificationManager.showError(
                        MediaUploadOutcomeMessage.queued(
                            hosts = unreachableServers.mapNotNull { hostOf(it) },
                            macHost = macHost,
                        ),
                        ErrorStyle.WARNING,
                    )
                    _isPublishing.value = false
                    onPublished()
                    return@launch
                }

                // 2b. Add p-tags for inline @mentions (nostr:npub/nprofile refs).
                tags.addAll(extractMentionPTags(finalContent, tags))

                // 2c. NIP-24 `t` tags. Without these a note typed with #bitcoin
                // is invisible to hashtag feeds — including our own search,
                // which builds its trending list from `t` tags. Read from
                // finalContent so a hashtag inside a `nostr:` reference or a
                // media URL is excluded.
                tags.addAll(NoteTagging.hashtagTags(finalContent))

                // 2d. NIP-92 `imeta`, one per uploaded attachment, in content order.
                tags.addAll(NoteTagging.imetaTags(mediaDescriptors))

                // 3. Sign and publish — but not as an account switched to during
                // the upload: that would ask the new account's signer to sign it.
                val event = nostrService.signEventAsync(kind = eventKind, content = finalContent, tags = tags, lockedTo = lock)
                if (event != null) {
                    // Checked again here, on the main thread in the same turn that
                    // hands the note to PendingPostManager, so no switch can slip
                    // in between the check and the hand-off.
                    nostrService.requireStillPostingAs(lock, eventPubkey = event.pubkey)
                    // Optimistic insert: inject the note immediately so the thread
                    // view shows it before relay confirmation (mirrors iOS behavior).
                    feedService.emitOptimisticNote(
                        FeedNote.fromEvent(
                            id = event.id,
                            pubkey = event.pubkey,
                            content = finalContent,
                            tags = tags,
                            createdAt = event.createdAt,
                            kind = eventKind,
                        )
                    )
                    val replyNote = replyToNoteId?.let { feedService.findNote(it) }
                    val quoteNote = quoteTarget()
                    pendingPostManager.startPost(
                        event = event,
                        content = finalContent,
                        replyTo = replyNote,
                        quoteTo = quoteNote,
                    ) { evt, onOutcome ->
                        nostrService.postEvent(evt, onBroadcastOutcome = onOutcome)
                    }
                    // Delete draft on successful publish
                    autoSaveJob?.cancel()
                    draftService.deleteDraft(draftId)
                    onPublished()
                } else {
                    Log.e("ComposeNote", "signEventAsync returned null for kind=$eventKind")
                    _error.value = "Failed to sign note"
                }
            } catch (e: PostingAccount.AccountChangedException) {
                // Keep the note: save it as a draft now (the debounced autosave
                // may not have run), and show a banner in case the switch closed
                // this screen.
                if (text.isNotBlank()) {
                    draftService.saveDraft(
                        Draft(
                            id = draftId,
                            content = convertMentionsToNostr(text),
                            replyToId = replyToNoteId,
                            quoteId = quoteCitedId(),
                        )
                    )
                }
                val message = if (text.isNotBlank()) PostingAccount.NOTE_MESSAGE else PostingAccount.MESSAGE
                notificationManager.showError(message)
                _error.value = message
            } catch (e: Exception) {
                Log.e("ComposeNote", "publish failed", e)
                _error.value = e.message ?: "Failed to publish"
            }
            _isPublishing.value = false
        }
    }

    /** How the attachments of one post ended up. */
    private sealed class AttachmentUploadResult {
        /**
         * Every attachment is at least on this device. A null [QueuedMediaPost.Media.url]
         * means no outside server took it yet; [unreachableServers] is what was tried.
         */
        data class Done(
            val media: List<QueuedMediaPost.Media>,
            val unreachableServers: List<String>,
        ) : AttachmentUploadResult()

        /** The post cannot be sent or queued; [message] says why. */
        data class Failed(val message: String) : AttachmentUploadResult()
    }

    private suspend fun uploadAttachments(): AttachmentUploadResult = withContext(Dispatchers.IO) {
        val uploaded = mutableListOf<QueuedMediaPost.Media>()
        // Set once an attachment found every outside server down; the rest of
        // this post's attachments are then saved on this device only, instead
        // of each waiting out the same 10 s retry.
        var unreachableServers: List<String> = emptyList()
        val notSaved = AttachmentUploadResult.Failed(MediaUploadOutcomeMessage.NOT_SAVED_ON_DEVICE)

        for ((index, attachment) in _attachments.value.withIndex()) {
            // Picked from the relay: already hosted, publish its URL as-is.
            if (attachment.hostedUrl != null) {
                val pixelSize = attachment.localFile?.takeIf { it.exists() }?.let { pixelSize(it, attachment.isVideo) }
                uploaded.add(
                    QueuedMediaPost.Media(
                        sha256 = attachment.sha256,
                        mimeType = attachment.mimeType.takeUnless { it.endsWith("/*") },
                        url = attachment.hostedUrl,
                        pixelWidth = pixelSize?.first,
                        pixelHeight = pixelSize?.second,
                        alt = attachment.altText,
                        byteCount = attachment.byteCount,
                    )
                )
                continue
            }
            withContext(Dispatchers.Main) {
                val mediaType = if (attachment.isVideo) "video" else "image"
                _uploadMessage.value = "Uploading $mediaType (${index + 1} of ${_attachments.value.size})..."
            }

            try {
                // Read file from URI
                val inputStream = context.contentResolver.openInputStream(attachment.uri)
                    ?: return@withContext notSaved

                val tempFile = File.createTempFile("upload_", ".tmp", context.cacheDir)
                tempFile.outputStream().use { output ->
                    inputStream.use { input ->
                        input.copyTo(output)
                    }
                }

                // The location comes out before the hash: the blob is public
                // once uploaded (iOS #335).
                if (!MediaPrivacy.removeLocation(tempFile, attachment.mimeType)) {
                    tempFile.delete()
                    return@withContext AttachmentUploadResult.Failed(MediaPrivacy.FAILURE_MESSAGE)
                }

                // Compute SHA-256
                val sha256 = blossomService.computeSHA256(tempFile)

                // Measured from the file on disk, before it is deleted below.
                val pixelSize = pixelSize(tempFile, attachment.isVideo)
                val byteCount = tempFile.length()

                // Upload with progress
                val outcome = blossomService.uploadForPost(
                    fileURL = tempFile,
                    sha256 = sha256,
                    contentType = attachment.mimeType,
                    skipOutsideServers = unreachableServers.isNotEmpty(),
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

                val url = when (outcome) {
                    is BlossomService.PostUploadOutcome.Hosted -> outcome.url
                    is BlossomService.PostUploadOutcome.SavedOnDevice -> {
                        // Safe on this device; the post will wait for a server.
                        unreachableServers = outcome.unreachable
                        null
                    }
                    BlossomService.PostUploadOutcome.NoOutsideServer ->
                        return@withContext AttachmentUploadResult.Failed(MediaUploadOutcomeMessage.NO_OUTSIDE_SERVER)
                    BlossomService.PostUploadOutcome.NotSavedOnDevice ->
                        return@withContext notSaved
                }

                uploaded.add(
                    QueuedMediaPost.Media(
                        sha256 = sha256,
                        mimeType = attachment.mimeType,
                        url = url,
                        pixelWidth = pixelSize?.first,
                        pixelHeight = pixelSize?.second,
                        alt = attachment.altText,
                        byteCount = byteCount,
                    )
                )
            } catch (e: Exception) {
                Log.e("ComposeNote", "Upload failed", e)
                return@withContext notSaved
            }
        }

        withContext(Dispatchers.Main) {
            _uploadMessage.value = null
        }

        AttachmentUploadResult.Done(uploaded, unreachableServers)
    }

    /** Host of a server URL, for naming it in a message. */
    private fun hostOf(url: String): String? =
        runCatching { java.net.URI(url).host }.getOrNull()?.takeIf { it.isNotEmpty() }

    /**
     * Pixel dimensions of a local media file, as `width to height`.
     *
     * Images are measured from the header alone (`inJustDecodeBounds`) — an
     * `imeta dim` is worth one header read, not a full decode of a 12-megapixel
     * photo. Videos report the track's rotation separately from its width and
     * height, so a portrait clip shot on a phone measures landscape unless the
     * rotation is applied; getting that backwards would reserve a sideways box
     * in every client that trusts our `dim`.
     */
    private fun pixelSize(file: File, isVideo: Boolean): Pair<Int, Int>? = try {
        if (isVideo) {
            // MediaMetadataRetriever only became AutoCloseable at API 29 and
            // this app runs from 26, so it is released by hand.
            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(file.absolutePath)
                val w = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull()
                val h = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull()
                val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
                if (w == null || h == null || w <= 0 || h <= 0) null
                else if (rotation == 90 || rotation == 270) h to w
                else w to h
            } finally {
                retriever.release()
            }
        } else {
            val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.absolutePath, options)
            if (options.outWidth > 0 && options.outHeight > 0) options.outWidth to options.outHeight else null
        }
    } catch (e: Exception) {
        // A note without `dim` still publishes; it just makes readers measure.
        Log.w("ComposeNote", "Could not measure media dimensions", e)
        null
    }

    /**
     * Build reply tags and the kind to sign them with. Answering a NIP-22
     * comment (kind 1111) sends a comment scoped to the same root
     * ([NIP10Thread.commentReplyTags]); everything else is a kind 1 reply
     * with NIP-10 e-tags (root/reply markers) + p-tag for the author.
     * Returns an empty list and kind 1 for new top-level notes.
     */
    private fun buildReplyTags(): Pair<List<List<String>>, Int> {
        val parentId = replyToNoteId ?: return emptyList<List<String>>() to 1
        // A repost is answered as the note it carries: findNote on the
        // original's id can return the wrapper, whose kind (6) would make this
        // a NIP-22 comment and, for a bare repost, name the reposter.
        val parentNote = feedService.quoteTarget(parentId) ?: return emptyList<List<String>>() to 1

        val tags = mutableListOf<List<String>>()

        val effectiveParentKind = parentNote.effectiveKind
        // Automatic (Logen, 2026-10-03): a note gets a kind 1 reply, anything
        // else a NIP-22 comment. No switch to explain.
        val eventKind = NIP10Thread.replyKind(effectiveParentKind)
        if (eventKind == NIP10Thread.COMMENT_KIND) {
            // NIP-22: on a comment, copy its root and point at it; on anything
            // else the parent is the root (E, or A alone for addressables and
            // replaceables). The tags already name the parent author.
            tags.addAll(NIP10Thread.commentTags(
                parentId = parentNote.effectiveEventId,
                parentKind = effectiveParentKind,
                parentPubkey = parentNote.pubkey,
                parentTags = parentNote.tags,
                relayHint = configStore.config.value.nostrURL ?: "",
            ))
            // NIP-10 still holds for notification fan-out: carry the parent's
            // p tags (thread participants), deduplicated.
            val seen = mutableSetOf(parentNote.pubkey)
            for (tag in parentNote.tags) {
                if (tag.size >= 2 && tag[0] == "p" && seen.add(tag[1])) {
                    tags.add(listOf("p", tag[1]))
                }
            }
            return tags to eventKind
        }

        // Determine thread structure from parent's tags
        val parentETags = parentNote.tags.filter { it.size >= 2 && it[0] == "e" }
        val parentNonMentionETags = parentETags.filter { it.size < 4 || it[3] != "mention" }

        val parentNonMentionATags = parentNote.tags.filter { it.size >= 2 && it[0] == "a" }
            .filter { it.size < 4 || it[3] != "mention" }

        if (parentNonMentionETags.isEmpty()) {
            // Parent IS the root note — single e-tag with "root" marker. NIP-10: the
            // optional 5th element is the event author's pubkey, used by the outbox
            // model to know whose relays to fetch it from.
            tags.add(listOf("e", parentNote.id, "", "root", parentNote.pubkey))
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
            tags.add(listOf("e", parentNote.id, "", "reply", parentNote.pubkey))

            // A legacy thread under an addressable root carries its coordinate
            // forward. a/A tags have no marker field.
            val rootATag = parentNonMentionATags.firstOrNull { it.size >= 4 && it[3] == "root" }
                ?: parentNonMentionATags.firstOrNull()
            rootATag?.let { tags.add(listOf("a", it[1], "")) }
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

        return tags to eventKind
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

/**
 * Whether closing the composer with [content] asks to keep it as a draft: more
 * than a stray word, the same bar iOS ComposeView.handleCancelTapped uses.
 */
internal fun composeNeedsDraftPrompt(content: String): Boolean {
    val trimmed = content.trim()
    return trimmed.isNotEmpty() && (trimmed.contains(' ') || trimmed.length > 10)
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
    val fetchingGif by viewModel.isFetchingGif.collectAsState()
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
    // "Save this note as a draft?" — the X and the back gesture both ask once
    // there is something worth keeping (iOS ComposeView).
    var showDraftPrompt by remember { mutableStateOf(false) }
    val requestClose: () -> Unit = {
        if (viewModel.shouldAskToSaveDraft()) showDraftPrompt = true else onBack()
    }
    BackHandler(enabled = !isPublishing, onBack = requestClose)
    // The attachment whose ALT text is being written; null = sheet closed.
    var altEditorTarget by remember { mutableStateOf<Attachment?>(null) }
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

    val pickerMaxItems = pickerMaxItems(attachments.size)
    val attachmentLimitReached = attachments.size >= MAX_ATTACHMENTS

    // Image picker launcher
    if (showDraftPrompt) {
        AlertDialog(
            onDismissRequest = { showDraftPrompt = false },
            title = { Text("Save this note as a draft?") },
            confirmButton = {
                TextButton(onClick = {
                    showDraftPrompt = false
                    viewModel.saveDraftNow()
                    onBack()
                }) { Text("Save Draft") }
            },
            dismissButton = {
                Row {
                    TextButton(onClick = {
                        showDraftPrompt = false
                        viewModel.discardDraft()
                        onBack()
                    }) { Text("Discard", color = ErrorRed) }
                    TextButton(onClick = { showDraftPrompt = false }) { Text("Keep Editing") }
                }
            },
        )
    }

    var showGifPicker by remember { mutableStateOf(false) }
    if (showGifPicker) {
        val saveGifs by viewModel.saveGifsToBlossom.collectAsState()
        com.nostrvault.ui.components.GifPickerSheet(
            onPick = { gif ->
                showGifPicker = false
                viewModel.pickGif(gif)
            },
            onDismiss = { showGifPicker = false },
            saveToBlossom = saveGifs,
            onSaveToBlossomChange = viewModel::setSaveGifsToBlossom,
        )
    }
    val imagePickerLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickMultipleVisualMedia(maxItems = pickerMaxItems)
    ) { uris ->
        if (uris.isNotEmpty()) {
            viewModel.addAttachments(uris)
        }
    }

    // Video picker launcher
    val videoPickerLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickMultipleVisualMedia(maxItems = pickerMaxItems)
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
                    IconButton(onClick = requestClose) {
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
                        enabled = (content.isNotBlank() || attachments.isNotEmpty()) && !isPublishing && !isUploading && !fetchingGif,
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
                    onEditAlt = { altEditorTarget = it },
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
                    enabled = !attachmentLimitReached
                ) {
                    Icon(
                        imageVector = Icons.Default.Image,
                        contentDescription = "Add image",
                        tint = colors.primary,
                        modifier = Modifier.size(20.dp)
                    )
                }

                // GIF picker (nostr.build). Hidden when this build has no API
                // key: a picker that finds nothing must not ship.
                if (com.nostrvault.data.gif.NostrBuildGifs.isConfigured) {
                    IconButton(
                        onClick = { showGifPicker = true },
                        enabled = !fetchingGif,
                        modifier = Modifier
                            .size(40.dp)
                            .background(colors.primary.copy(alpha = 0.1f), CircleShape),
                    ) {
                        if (fetchingGif) {
                            CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = colors.primary)
                        } else {
                            Text("GIF", color = colors.primary, fontSize = 11.sp, fontWeight = FontWeight.Black)
                        }
                    }
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
                    enabled = !attachmentLimitReached
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
                    enabled = !attachmentLimitReached
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

    // ALT-text sheet for one attachment
    altEditorTarget?.let { target ->
        AltTextSheet(
            attachment = target,
            onDismiss = { altEditorTarget = null },
            onSave = { alt ->
                viewModel.setAttachmentAlt(target.id, alt)
                altEditorTarget = null
            },
        )
    }

    // Blossom media picker sheet
    if (showBlossomPicker) {
        BlossomMediaPickerSheet(
            onDismiss = { viewModel.setShowBlossomPicker(false) },
            onSelect = { item -> viewModel.addBlossomMedia(item) },
            loadItems = viewModel::loadBlossomMediaItems,
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
    onEditAlt: (Attachment) -> Unit,
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

                // ALT chip: filled once the attachment has a description,
                // hollow while it has none, so an undescribed image is visible
                // as such at a glance rather than only after publishing.
                val described = attachment.altText.isNotBlank()
                Text(
                    text = "ALT",
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Bold,
                    color = Color.White,
                    modifier = Modifier
                        .align(Alignment.BottomStart)
                        .padding(6.dp)
                        .clip(RoundedCornerShape(50))
                        .background(
                            if (described) LocalNostrVaultColors.current.primary
                            else Color.Black.copy(alpha = 0.55f)
                        )
                        .clickable { onEditAlt(attachment) }
                        .padding(horizontal = 8.dp, vertical = 4.dp)
                        .semantics {
                            contentDescription =
                                if (described) "Edit description: ${attachment.altText}"
                                else "Add a description for this media"
                        }
                )
            }
        }
    }
}

/**
 * Sheet for writing one attachment's NIP-92 `alt` text.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AltTextSheet(
    attachment: Attachment,
    onDismiss: () -> Unit,
    onSave: (String) -> Unit,
) {
    var text by remember(attachment.id) { mutableStateOf(attachment.altText) }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                text = "Describe this media",
                fontSize = 18.sp,
                fontWeight = FontWeight.SemiBold,
                color = PrimaryText,
            )
            Text(
                text = "Published as the image's ALT text. Screen readers read this instead of the picture.",
                fontSize = 13.sp,
                color = SecondaryText,
            )
            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 100.dp)
                    .semantics { contentDescription = "Media description" },
                placeholder = { Text("A cat asleep on a keyboard") },
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.End,
            ) {
                TextButton(onClick = onDismiss) { Text("Cancel") }
                Spacer(modifier = Modifier.width(8.dp))
                Button(onClick = { onSave(text) }) { Text("Save") }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
internal fun BlossomMediaPickerSheet(
    onDismiss: () -> Unit,
    onSelect: (BlossomMediaItem) -> Unit,
    /** Shared with the live stream chat, so the loader comes from the caller. */
    loadItems: suspend () -> List<BlossomMediaItem>,
) {
    val context = LocalContext.current
    val colors = LocalNostrVaultColors.current
    var blossomMedia by remember { mutableStateOf<List<BlossomMediaItem>>(emptyList()) }
    var isLoading by remember { mutableStateOf(true) }
    // The Media tab's type filter, shared both ways as on iOS.
    val (typeSelection, onTypeTap) = rememberMediaTypeSelection()
    // The Media tab's sort, so the headings match what that tab shows (iOS
    // reads the same MediaSortOption setting).
    val sortOption = remember {
        MediaSortOption.fromKey(
            context.getSharedPreferences(MEDIA_GALLERY_PREFS, Context.MODE_PRIVATE)
                .getString(MediaSortOption.STORAGE_KEY, null),
        )
    }
    val shownMedia = remember(blossomMedia, typeSelection) {
        sortOption.sorted(blossomMedia.filter { MediaTypeSelection.matches(typeSelection, it) })
    }
    val sections = remember(shownMedia) { MediaDateGrouping.sections(shownMedia, sortOption) }

    LaunchedEffect(Unit) {
        withContext(Dispatchers.IO) {
            try {
                // Load blossom media from local relay
                val items = loadItems()
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
        // The grid runs 8 from the edges; the title and filter keep 16.
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 16.dp)
        ) {
            Text(
                text = "Pick from Blossom",
                fontSize = 20.sp,
                fontWeight = FontWeight.Bold,
                color = PrimaryText,
                modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 8.dp)
            )
            // The Media tab's filter; the composer attaches photos and videos only.
            Box(modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 12.dp)) {
                MediaTypeFilterPill(
                    selection = typeSelection,
                    onSelect = onTypeTap,
                    filters = listOf(
                        MediaTypeFilter.ALL,
                        MediaTypeFilter.PHOTO,
                        MediaTypeFilter.VIDEO,
                        MediaTypeFilter.GIF,
                    ),
                )
            }

            if (isLoading) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(200.dp),
                    contentAlignment = Alignment.Center
                ) {
                    CircularProgressIndicator(color = colors.primary)
                }
            } else if (shownMedia.isEmpty()) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(200.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        text = if (blossomMedia.isEmpty()) "No media on Blossom" else "Nothing of this type",
                        color = SecondaryText,
                        fontSize = 14.sp
                    )
                }
            } else {
                // The Media tab's date headings, pinned while their run
                // scrolls, with iOS's 6 between cells, 8 between rows and 8 at
                // the edges. A grid has no pinned headers in this Compose
                // version, so rows of three go in a list.
                LazyColumn(
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                    contentPadding = PaddingValues(start = 8.dp, end = 8.dp, bottom = 8.dp),
                    modifier = Modifier.heightIn(max = 400.dp)
                ) {
                    for (section in sections) {
                        if (section.title.isNotEmpty()) {
                            stickyHeader(key = "header:${section.title}") { MediaSectionHeader(section.title) }
                        }
                        items(section.items.chunked(3), key = { row -> row.first().sha256 }) { row ->
                            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                row.forEach { item ->
                                    Box(
                                        modifier = Modifier
                                            .weight(1f)
                                            .aspectRatio(1f)
                                            .clip(RoundedCornerShape(8.dp))
                                            .combinedClickable(
                                                onClick = { onSelect(item) },
                                                onLongClick = {
                                                    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                                                    clipboard.setPrimaryClip(ClipData.newPlainText("Blossom URL", item.displayUrl))
                                                    Toast.makeText(context, "Link copied", Toast.LENGTH_SHORT).show()
                                                }
                                            )
                                    ) {
                                        AsyncImage(
                                            model = item.localFile ?: item.displayUrl,
                                            contentDescription = null,
                                            modifier = Modifier.fillMaxSize(),
                                            contentScale = ContentScale.Crop
                                        )

                                        if (item.isVideo) {
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
                                // A short last row keeps its cells the same size.
                                repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
                            }
                        }
                    }
                }
            }

            Spacer(Modifier.height(16.dp))
        }
    }
}
