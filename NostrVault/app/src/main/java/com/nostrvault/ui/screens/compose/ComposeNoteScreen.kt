package com.nostrvault.ui.screens

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import com.nostrvault.data.model.Draft
import com.nostrvault.ui.components.AccountSwitcherSheet
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.components.QuotedNoteCard
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.launch

/**
 * Compose new note screen with text input and publish action.
 * Supports replying to notes via NIP-10 e/p tags.
 */

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
    val replyParent by viewModel.replyParent.collectAsState()
    val replyParentPicture by viewModel.replyParentPicture.collectAsState()
    val replyParentPreview by viewModel.replyParentPreview.collectAsState()
    // iOS focuses the editor 0.3s after the composer opens.
    val editorFocus = remember { FocusRequester() }
    LaunchedEffect(Unit) {
        kotlinx.coroutines.delay(300)
        runCatching { editorFocus.requestFocus() }
    }
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
    // Mid-send there is nothing to ask: the post keeps going after the
    // composer closes (ComposeNoteViewModel.publish), as on iPhone.
    BackHandler(onBack = if (isPublishing) onBack else requestClose)
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
                    IconButton(onClick = if (isPublishing) onBack else requestClose) {
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
        // The editor fills what the keyboard leaves; the name chips, attached
        // media and toolbar dock on the keyboard edge so none of them hides
        // behind it or pushes the line being typed out of sight (iOS #532).
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .consumeWindowInsets(padding)
                .imePadding()
                .mediaDropTarget(enabled = !isPublishing && !attachmentLimitReached) { viewModel.addAttachments(it) },
        ) {
        Column(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
                .padding(start = 16.dp, end = 16.dp, top = 16.dp),
        ) {
            // Reply header (iOS ComposeView.replyHeader): the parent's avatar
            // on a thread line, "Replying to X...", then its text in 3 lines.
            replyParent?.let { parent ->
                ComposeReplyHeader(
                    parent = parent,
                    name = replyingToName ?: parent.pubkey.take(8),
                    pictureUrl = replyParentPicture,
                    preview = replyParentPreview,
                    modifier = Modifier.padding(bottom = 16.dp),
                )
            }

            // Posting-as avatar beside the editor (iOS: 36pt, long-press
            // switches the posting account).
            Row(
                verticalAlignment = Alignment.Top,
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f),
            ) {
                AvatarImage(
                    url = activeAccount?.avatarUrl,
                    pubkey = activeAccount?.hexPubkey ?: "",
                    size = 36.dp,
                    displayName = activeAccount?.displayName,
                    modifier = Modifier
                        .padding(top = 8.dp)
                        .combinedClickable(
                            onClickLabel = null,
                            onLongClickLabel = "Switch account",
                            onClick = {},
                            onLongClick = { showAccountSwitcher = true },
                        )
                        .semantics {
                            contentDescription = "Posting as ${activeAccount?.displayName ?: "Owner"}"
                        },
                )
                Spacer(Modifier.width(12.dp))

                Column(modifier = Modifier.weight(1f)) {
                    // Text input
                    OutlinedTextField(
                        value = textFieldValue,
                        onValueChange = { newValue ->
                            textFieldValue = newValue
                            viewModel.onContentChanged(newValue.text, newValue.selection.start)
                        },
                        // iOS shows the same prompt for a note, reply or quote.
                        placeholder = { Text("What's happening?", color = PlaceholderText) },
                        // Fills the space left and scrolls itself, which keeps the
                        // caret in view while typing.
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedBorderColor = Color.Transparent,
                            unfocusedBorderColor = Color.Transparent,
                            cursorColor = colors.primary,
                        ),
                        modifier = Modifier
                            .fillMaxWidth()
                            .weight(1f)
                            .focusRequester(editorFocus),
                    )

                    // Quoted note under the text, as on iOS. Capped so a long
                    // quote can't squeeze the editor shut.
                    quotedNote?.let { qNote ->
                        QuotedNoteCard(
                            note = qNote,
                            profile = quotedProfile,
                            onClick = { /* non-interactive in compose */ },
                            modifier = Modifier
                                .padding(top = 12.dp, bottom = 8.dp)
                                .heightIn(max = 280.dp)
                                .clip(RoundedCornerShape(8.dp)),
                        )
                    }
                }
            }
        }

        // Docked above the keyboard.
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 8.dp),
        ) {
            // @mention suggestions
            if (mentionResults.isNotEmpty()) {
                MentionSuggestions(
                    results = mentionResults,
                    onSelect = { profile ->
                        viewModel.insertMention(profile)?.let { (newText, caret) ->
                            textFieldValue = TextFieldValue(newText, TextRange(caret))
                        }
                    },
                    modifier = Modifier.padding(bottom = 8.dp),
                )
            }

            // Attachment grid preview
            if (attachments.isNotEmpty()) {
                AttachmentGrid(
                    attachments = attachments,
                    onRemove = { viewModel.removeAttachment(it) },
                    onEditAlt = { altEditorTarget = it },
                    modifier = Modifier.padding(bottom = 8.dp)
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
                Spacer(Modifier.height(8.dp))
            }

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

                // GIF picker (nostr.build), after paste as on iOS (photo,
                // video, paste, GIF). Hidden when this build has no API
                // key: a picker that finds nothing must not ship.
                if (com.nostrvault.data.gif.NostrBuildGifs.isConfigured) {
                    IconButton(
                        onClick = { showGifPicker = true },
                        enabled = !fetchingGif && !attachmentLimitReached,
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

/** iOS ComposeView.replyHeader: who you are answering and what they said. */
@Composable
private fun ComposeReplyHeader(
    parent: com.nostrvault.data.model.FeedNote,
    name: String,
    pictureUrl: String?,
    preview: String,
    modifier: Modifier = Modifier,
) {
    val accent = LocalNostrVaultColors.current.primary
    Row(
        modifier = modifier
            .fillMaxWidth()
            .height(IntrinsicSize.Min)
            .clip(RoundedCornerShape(12.dp))
            .background(accent.copy(alpha = 0.05f))
            .border(1.dp, accent.copy(alpha = 0.15f), RoundedCornerShape(12.dp))
            .padding(12.dp),
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            AvatarImage(url = pictureUrl, pubkey = parent.pubkey, size = 32.dp, displayName = name)
            Box(
                Modifier
                    .width(2.dp)
                    .weight(1f)
                    .background(accent.copy(alpha = 0.3f)),
            )
        }
        Spacer(Modifier.width(12.dp))
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                text = "Replying to $name...",
                color = SecondaryText,
                fontSize = 13.sp,
                fontWeight = FontWeight.Bold,
            )
            // A note that is nothing but a quote strips to empty; the line
            // above already carries the context.
            if (preview.isNotEmpty()) {
                Text(
                    text = preview,
                    color = SecondaryText.copy(alpha = 0.7f),
                    fontSize = 13.sp,
                    maxLines = 3,
                    overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                    modifier = Modifier.padding(bottom = 4.dp),
                )
            }
        }
    }
}
