package com.nostrvault.ui.screens

import com.nostrvault.service.readsForeignUri
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import android.util.Log
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.model.Draft
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.MediaUploadOutcomeMessage
import com.nostrvault.data.model.NoteTagging
import com.nostrvault.data.model.PostingAccount
import com.nostrvault.data.model.QueuedMediaPost
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.service.BlossomService
import com.nostrvault.service.DraftService
import com.nostrvault.service.FeedService
import com.nostrvault.service.MediaPostQueue
import com.nostrvault.service.NostrService
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.PendingPostManager
import com.nostrvault.ui.components.AccountInfo
import com.nostrvault.ui.components.buildAccountInfos
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
import com.nostrvault.data.gif.GifCache
import javax.inject.Inject

@HiltViewModel
class ComposeNoteViewModel @Inject constructor(
    internal val nostrService: NostrService,
    internal val feedService: FeedService,
    private val pendingPostManager: PendingPostManager,
    private val draftService: DraftService,
    internal val blossomService: BlossomService,
    internal val configStore: ConfigStore,
    private val mediaPostQueue: MediaPostQueue,
    private val notificationManager: NotificationManager,
    private val blossomPickerMedia: BlossomPickerMedia,
    @ApplicationContext internal val context: Context,
    savedStateHandle: SavedStateHandle,
) : ViewModel() {

    internal val replyToNoteId: String? = savedStateHandle["replyTo"]
    private val quoteToNoteId: String? = savedStateHandle["quoteTo"]
    private val resumeDraftId: String? = savedStateHandle["draftId"]
    /** Text to start with, e.g. a song shared from the music player. */
    private val initialText: String? = savedStateHandle["text"]

    /** Stable draft ID for this compose session. */
    private val draftId: String = resumeDraftId ?: java.util.UUID.randomUUID().toString()
    private var autoSaveJob: Job? = null

    /**
     * True once the composer screen is gone. A send keeps running after that
     * (see [publish]), but must not pop whatever screen is showing now, and
     * reports a failure as a banner since nobody sees this screen's error.
     */
    @Volatile private var screenGone = false

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

    internal val _attachments = MutableStateFlow<List<Attachment>>(emptyList())
    val attachments = _attachments.asStateFlow()

    private val _isUploading = MutableStateFlow(false)
    val isUploading = _isUploading.asStateFlow()

    internal val _uploadMessage = MutableStateFlow<String?>(null)
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
    internal val _mentionResults = MutableStateFlow<List<FeedProfile>>(emptyList())
    val mentionResults = _mentionResults.asStateFlow()

    /** Char offsets of the active `@query` token in `content` (start = the `@`). */
    internal var mentionStartOffset: Int? = null
    internal var mentionEndOffset: Int? = null

    /** The query of the mention currently being edited, and its debounced relay search. */
    internal var currentMentionQuery: String? = null
    internal var mentionSearchJob: Job? = null

    /**
     * Maps an inserted display token (e.g. "@Alice") → hex pubkey. The editor shows
     * `@name` for readability; tokens are converted back to `nostr:npub…` at publish
     * and draft-save time so published notes stay interoperable.
     */
    internal val mentionMap = mutableMapOf<String, String>()

    val isReply: Boolean get() = replyToNoteId != null

    val isQuote: Boolean get() = quoteToNoteId != null

    /**
     * The note this quote cites. Resolved through [FeedService.quoteTarget] so
     * quoting a repost cites the original's id and author, not the reposter.
     */
    internal fun quoteTarget(): FeedNote? = quoteToNoteId?.let { feedService.quoteTarget(it) }

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
                val file = withContext(Dispatchers.IO) {
                    GifCache.newFile(context.cacheDir, mime).apply { writeBytes(bytes) }
                }
                if (_attachments.value.size < MAX_ATTACHMENTS) {
                    _attachments.value = _attachments.value + Attachment(uri = Uri.fromFile(file), mimeType = mime)
                } else {
                    file.delete()
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
        _attachments.value.firstOrNull { it.id == id }?.let { GifCache.deleteIfOwned(it.uri, context.cacheDir) }
        _attachments.value = _attachments.value.filter { it.id != id }
    }

    /** The downloaded GIFs behind [attachments]; the upload has its own copy by now. */
    private fun deleteGifCopies(attachments: List<Attachment>) {
        attachments.forEach { GifCache.deleteIfOwned(it.uri, context.cacheDir) }
    }

    /** Leaving without posting: drafts keep only text, so the GIF copies have no further use. */
    override fun onCleared() {
        screenGone = true
        // A send still running reads these; it deletes them when it ends.
        if (!_isPublishing.value) deleteGifCopies(_attachments.value)
        super.onCleared()
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
            mimeType = mime ?: when {
                item.isVideo -> "video/*"
                item.isAudio -> "audio/*"
                else -> "image/*"
            },
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
                // Another app may have put it there: never one of our own files.
                if (!context.readsForeignUri(uri)) {
                    notificationManager.showError(com.nostrvault.service.FOREIGN_URI_REFUSED)
                    return
                }
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
        // This draft may still be sending from an earlier visit to the
        // composer (left mid-upload, then reopened from Drafts): a second
        // send would post the same note twice.
        if (pendingPostManager.isSending(draftId)) {
            _error.value = ALREADY_SENDING
            notificationManager.showError(ALREADY_SENDING)
            return
        }

        val lock = nostrService.lockPostingAccount()

        // On disk before the send starts, so a crash or a killed app during
        // the upload leaves the text in Drafts. The draft goes once the post
        // does (iOS ComposeView.postNote does the same).
        // [sentVersion] is that save: the draft can be reopened from Drafts
        // and edited while this send runs, and those edits must outlive it.
        autoSaveJob?.cancel()
        val sentVersion = if (text.isNotBlank()) {
            draftService.saveDraft(
                Draft(
                    id = draftId,
                    content = convertMentionsToNostr(text),
                    replyToId = replyToNoteId,
                    quoteId = quoteCitedId(),
                )
            ).updatedAt
        } else {
            null
        }

        // Not viewModelScope: leaving the composer mid-send would cancel the
        // upload and the post with it. iOS keeps going after its sheet closes.
        pendingPostManager.launchSend(draftId) {
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
                            reportSendError(result.message)
                            finishSend()
                            return@launchSend
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

                // What Edit on the countdown banner brings back: the text and
                // the uploaded media's URLs (a draft keeps only text), but not
                // the quote's nostr: line, which publish appends again.
                val editableContent = finalContent

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
                    draftService.deleteSentDraft(draftId, sentVersion)
                    val macHost = configStore.config.value.macRelayHttpsURL
                        .takeIf { it.isNotEmpty() }?.let { hostOf(it) }
                    notificationManager.showError(
                        MediaUploadOutcomeMessage.queued(
                            hosts = unreachableServers.mapNotNull { hostOf(it) },
                            macHost = macHost,
                        ),
                        ErrorStyle.WARNING,
                    )
                    // Posted or queued: the upload kept its own copy, so the GIF copies go.
                    deleteGifCopies(_attachments.value)
                    finishSend()
                    if (!screenGone) onPublished()
                    return@launchSend
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
                    // The draft lives until the post goes out, so Cancel on
                    // the banner keeps the text and Edit reopens it (iOS
                    // PendingPostManager.startPost(draftId:)).
                    autoSaveJob?.cancel()
                    val keptDraft = Draft(
                        id = draftId,
                        content = editableContent,
                        pubkey = event.pubkey,
                        replyToId = replyToNoteId,
                        quoteId = quotedId,
                    )
                    pendingPostManager.startPost(
                        event = event,
                        content = editableContent,
                        replyTo = replyNote,
                        quoteTo = quoteNote,
                        draftId = draftId,
                        replyToId = replyToNoteId,
                        quoteToId = quoteToNoteId,
                        onWithdrawn = { draftService.restoreWithdrawnDraft(keptDraft, sentVersion) },
                    ) { evt, onOutcome ->
                        nostrService.postEvent(evt, onBroadcastOutcome = onOutcome)
                        // Out the door: its draft (an autosave, or one kept by
                        // an earlier Cancel) has no further use, unless it was
                        // edited again since the tap.
                        draftService.deleteSentDraft(keptDraft.id, sentVersion)
                    }
                    // Posted or queued: the upload kept its own copy, so the GIF copies go.
                    deleteGifCopies(_attachments.value)
                    finishSend()
                    if (!screenGone) onPublished()
                    return@launchSend
                } else {
                    Log.e("ComposeNote", "signEventAsync returned null for kind=$eventKind")
                    reportSendError("Failed to sign note")
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
                reportSendError(e.message ?: "Failed to publish")
            }
            finishSend()
        }
    }

    companion object {
        internal const val ALREADY_SENDING = "This note is still sending. It will show up in a moment."
    }

    /** On the screen if it is still open, otherwise as a banner over whatever is. */
    private fun reportSendError(message: String) {
        _error.value = message
        if (screenGone) notificationManager.showError(message)
    }

    /** The send is over; the GIF copies [onCleared] left for it go now. */
    private fun finishSend() {
        _isUploading.value = false
        _isPublishing.value = false
        if (screenGone) deleteGifCopies(_attachments.value)
    }

    /** How the attachments of one post ended up. */
    internal sealed class AttachmentUploadResult {
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
}
