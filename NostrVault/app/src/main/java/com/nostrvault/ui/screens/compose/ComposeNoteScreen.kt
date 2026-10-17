package com.nostrvault.ui.screens

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
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
import androidx.compose.ui.semantics.contentDescription
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
            // Capped so a long quote can't squeeze the editor shut.
            quotedNote?.let { qNote ->
                QuotedNoteCard(
                    note = qNote,
                    profile = quotedProfile,
                    onClick = { /* non-interactive in compose */ },
                    modifier = Modifier
                        .padding(bottom = 12.dp)
                        .heightIn(max = 140.dp)
                        .clip(RoundedCornerShape(12.dp)),
                )
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
                // Fills the space left and scrolls itself, which keeps the
                // caret in view while typing.
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = Color.Transparent,
                    unfocusedBorderColor = Color.Transparent,
                    cursorColor = colors.primary,
                ),
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f),
            )
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
