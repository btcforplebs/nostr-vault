package com.nostrvault.ui.screens

import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.model.Draft
import com.nostrvault.data.model.DraftReplyParent
import com.nostrvault.data.model.FeedNote
import com.nostrvault.service.DraftService
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import java.text.SimpleDateFormat
import java.util.*
import javax.inject.Inject

@HiltViewModel
class DraftsViewModel @Inject constructor(
    private val draftService: DraftService,
    private val nostrService: NostrService,
    private val feedService: FeedService,
) : ViewModel() {
    val drafts = draftService.drafts
    val profiles = nostrService.profiles

    private val _parents = MutableStateFlow<Map<String, FeedNote>>(emptyMap())
    /** The notes reply drafts answer, by id, once loaded. */
    val parents: StateFlow<Map<String, FeedNote>> = _parents.asStateFlow()
    private val asked = mutableSetOf<String>()

    /** Loads the note [draft] replies to (memory first, then relays) and its author's profile. Once per id. */
    fun loadParent(draft: Draft) {
        val id = draft.replyToId ?: return
        DraftReplyParent.parentPubkey(draft)?.let { askProfile(it) }
        if (!asked.add(id)) return
        feedService.findNote(id)?.let { found ->
            _parents.update { it + (id to found) }
            askProfile(found.pubkey)
            return
        }
        nostrService.fetchNoteById(id) { note ->
            if (note == null) return@fetchNoteById
            viewModelScope.launch {
                _parents.update { it + (id to note) }
                askProfile(note.pubkey)
            }
        }
    }

    private fun askProfile(pubkey: String) {
        if (pubkey.isNotEmpty() && nostrService.profiles.value[pubkey] == null) {
            nostrService.fetchMissingProfiles(listOf(pubkey))
        }
    }

    init {
        // Pick up drafts saved on another device (iOS: DraftPickerView.onAppear).
        draftService.refreshFromRelay()
    }

    fun deleteDraft(draftId: String) {
        draftService.deleteDraft(draftId)
    }

    /** Snapshot the ids first — deleting mutates the flow this list came from. */
    fun deleteDrafts(draftIds: Collection<String>) {
        draftIds.toList().forEach { draftService.deleteDraft(it) }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DraftsScreen(
    onResumeDraft: (draftId: String, content: String, replyToId: String?, quoteToId: String?) -> Unit,
    onBack: () -> Unit,
    viewModel: DraftsViewModel = hiltViewModel(),
) {
    val drafts by viewModel.drafts.collectAsState()
    val parents by viewModel.parents.collectAsState()
    val profiles by viewModel.profiles.collectAsState()
    LaunchedEffect(drafts) { drafts.forEach { if (it.isReply) viewModel.loadParent(it) } }
    fun parentLine(draft: Draft): String? {
        val id = draft.replyToId ?: return null
        val parent = parents[id]
        val pubkey = parent?.pubkey ?: DraftReplyParent.parentPubkey(draft)
        val name = pubkey?.let { profiles[it]?.bestName } ?: pubkey?.take(8) ?: "someone"
        return DraftReplyParent.line(name, parent?.content)
    }
    val themeColors = LocalNostrVaultColors.current

    var isSelecting by remember { mutableStateOf(false) }
    val selectedIds = remember { mutableStateListOf<String>() }
    var confirmingBulkDelete by remember { mutableStateOf(false) }

    // Id of the draft a swipe is asking to delete, or null. Swiping is a
    // deliberate gesture, but the thing it destroys is unrecoverable — the same
    // sentence the bulk dialog already says — and the gesture is one drag away
    // from the scroll it shares an axis with. So a swipe *asks*, using the same
    // dialog and the same words as selecting one draft and hitting delete.
    var confirmingSwipeDelete by remember { mutableStateOf<String?>(null) }

    fun exitSelection() {
        isSelecting = false
        selectedIds.clear()
    }

    // Drafts can disappear underneath us (deleted here, or edited elsewhere and
    // re-saved), so drop selections that no longer exist rather than trying to
    // delete ids that are already gone.
    LaunchedEffect(drafts) {
        val live = drafts.map { it.id }.toSet()
        selectedIds.retainAll { it in live }
        if (isSelecting && drafts.isEmpty()) exitSelection()
    }

    confirmingSwipeDelete?.let { draftId ->
        AlertDialog(
            onDismissRequest = { confirmingSwipeDelete = null },
            title = { Text("Delete this draft?", fontWeight = FontWeight.Bold) },
            text = { Text("Deleted drafts are removed from your relay and can't be recovered.") },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.deleteDraft(draftId)
                    confirmingSwipeDelete = null
                }) { Text("Delete", color = ErrorRed, fontWeight = FontWeight.Bold) }
            },
            dismissButton = {
                TextButton(onClick = { confirmingSwipeDelete = null }) { Text("Cancel") }
            },
            containerColor = WindowBackground,
        )
    }

    if (confirmingBulkDelete) {
        AlertDialog(
            onDismissRequest = { confirmingBulkDelete = false },
            title = {
                Text(
                    if (selectedIds.size == 1) "Delete this draft?"
                    else "Delete ${selectedIds.size} drafts?",
                    fontWeight = FontWeight.Bold,
                )
            },
            text = { Text("Deleted drafts are removed from your relay and can't be recovered.") },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.deleteDrafts(selectedIds)
                    confirmingBulkDelete = false
                    exitSelection()
                }) { Text("Delete", color = ErrorRed, fontWeight = FontWeight.Bold) }
            },
            dismissButton = {
                TextButton(onClick = { confirmingBulkDelete = false }) { Text("Cancel") }
            },
            containerColor = WindowBackground,
        )
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        if (isSelecting) {
                            if (selectedIds.isEmpty()) "Select drafts" else "${selectedIds.size} selected"
                        } else "Drafts",
                        fontWeight = FontWeight.Bold,
                    )
                },
                navigationIcon = {
                    IconButton(onClick = { if (isSelecting) exitSelection() else onBack() }) {
                        Icon(NostrVaultIcons.Back, contentDescription = if (isSelecting) "Done" else "Back")
                    }
                },
                actions = {
                    if (drafts.isNotEmpty()) {
                        if (isSelecting) {
                            TextButton(onClick = {
                                if (selectedIds.size == drafts.size) selectedIds.clear()
                                else {
                                    selectedIds.clear()
                                    selectedIds.addAll(drafts.map { it.id })
                                }
                            }) {
                                Text(if (selectedIds.size == drafts.size) "None" else "All")
                            }
                            IconButton(
                                onClick = { confirmingBulkDelete = true },
                                enabled = selectedIds.isNotEmpty(),
                            ) {
                                Icon(
                                    NostrVaultIcons.Delete,
                                    contentDescription = "Delete selected",
                                    tint = if (selectedIds.isEmpty()) SecondaryText.copy(alpha = 0.4f) else ErrorRed,
                                )
                            }
                        } else {
                            TextButton(onClick = { isSelecting = true }) { Text("Select") }
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = WindowBackground,
                    titleContentColor = PrimaryText,
                    navigationIconContentColor = PrimaryText,
                    actionIconContentColor = PrimaryText,
                ),
            )
        },
        containerColor = WindowBackground,
    ) { padding ->
        if (drafts.isEmpty()) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Icon(
                        imageVector = NostrVaultIcons.Edit,
                        contentDescription = null,
                        tint = TertiaryText,
                        modifier = Modifier.size(48.dp),
                    )
                    Spacer(Modifier.height(12.dp))
                    Text(
                        text = "No drafts",
                        color = SecondaryText,
                        fontSize = 16.sp,
                    )
                    Text(
                        text = "Drafts are saved automatically as you type",
                        color = TertiaryText,
                        fontSize = 13.sp,
                    )
                }
            }
        } else {
            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                items(
                    items = drafts,
                    key = { it.id },
                ) { draft ->
                    val isChecked = draft.id in selectedIds
                    val toggle = {
                        if (isChecked) selectedIds.remove(draft.id) else selectedIds.add(draft.id)
                        Unit
                    }

                    if (isSelecting) {
                        // No swipe-to-dismiss while selecting — the horizontal
                        // drag would fight the tap-to-toggle and delete a draft
                        // the user was only trying to check.
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp),
                            modifier = Modifier.fillMaxWidth().clickable { toggle() },
                        ) {
                            Checkbox(
                                checked = isChecked,
                                onCheckedChange = { toggle() },
                                colors = CheckboxDefaults.colors(
                                    checkedColor = themeColors.primary,
                                    uncheckedColor = SecondaryText,
                                ),
                            )
                            Box(modifier = Modifier.weight(1f)) {
                                DraftCard(draft = draft, parentLine = parentLine(draft), onClick = toggle)
                            }
                        }
                        return@items
                    }

                    val dismissState = rememberSwipeToDismissBoxState(
                        confirmValueChange = { value ->
                            // Never accept the dismiss: the row springs back and
                            // the dialog decides. Accepting it here would animate
                            // the draft away before the user has said yes, and
                            // there is nothing to animate back if they say no.
                            if (value != SwipeToDismissBoxValue.Settled) {
                                confirmingSwipeDelete = draft.id
                            }
                            false
                        },
                    )

                    SwipeToDismissBox(
                        state = dismissState,
                        backgroundContent = {
                            val color by animateColorAsState(
                                if (dismissState.dismissDirection == SwipeToDismissBoxValue.EndToStart)
                                    ErrorRed.copy(alpha = 0.9f)
                                else ErrorRed.copy(alpha = 0.3f),
                                animationSpec = Motion.control(),
                                label = "dismiss-bg",
                            )
                            Box(
                                contentAlignment = Alignment.CenterEnd,
                                modifier = Modifier
                                    .fillMaxSize()
                                    .clip(RoundedCornerShape(12.dp))
                                    .background(color)
                                    .padding(end = 20.dp),
                            ) {
                                Icon(
                                    imageVector = NostrVaultIcons.Delete,
                                    contentDescription = "Delete",
                                    tint = PrimaryText,
                                )
                            }
                        },
                        enableDismissFromStartToEnd = false,
                    ) {
                        DraftCard(
                            draft = draft,
                            parentLine = parentLine(draft),
                            onClick = {
                                onResumeDraft(
                                    draft.id,
                                    draft.content,
                                    draft.replyToId,
                                    draft.quoteId,
                                )
                            },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun DraftCard(
    draft: Draft,
    parentLine: String?,
    onClick: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    val dateFormatter = remember {
        SimpleDateFormat("MMM d, h:mm a", Locale.getDefault())
    }

    Surface(
        shape = RoundedCornerShape(12.dp),
        color = SecondaryGroupedBg,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick),
    ) {
        Column(
            modifier = Modifier.padding(14.dp),
        ) {
            // Header row: type badge + timestamp
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                // Type indicator
                if (draft.isReply) {
                    Surface(
                        shape = RoundedCornerShape(6.dp),
                        color = colors.primary.copy(alpha = 0.15f),
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp),
                        ) {
                            Icon(
                                imageVector = NostrVaultIcons.Reply,
                                contentDescription = null,
                                tint = colors.primary,
                                modifier = Modifier.size(12.dp),
                            )
                            Spacer(Modifier.width(4.dp))
                            Text(
                                text = "Reply",
                                color = colors.primary,
                                fontSize = 11.sp,
                                fontWeight = FontWeight.SemiBold,
                            )
                        }
                    }
                    Spacer(Modifier.width(8.dp))
                } else if (draft.isQuote) {
                    Surface(
                        shape = RoundedCornerShape(6.dp),
                        color = colors.primary.copy(alpha = 0.15f),
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp),
                        ) {
                            Icon(
                                imageVector = NostrVaultIcons.Quote,
                                contentDescription = null,
                                tint = colors.primary,
                                modifier = Modifier.size(12.dp),
                            )
                            Spacer(Modifier.width(4.dp))
                            Text(
                                text = "Quote",
                                color = colors.primary,
                                fontSize = 11.sp,
                                fontWeight = FontWeight.SemiBold,
                            )
                        }
                    }
                    Spacer(Modifier.width(8.dp))
                }

                Spacer(Modifier.weight(1f))

                Text(
                    text = dateFormatter.format(Date(draft.updatedAt)),
                    color = TertiaryText,
                    fontSize = 12.sp,
                )
            }

            // Who and what a reply draft answers
            if (parentLine != null) {
                Spacer(Modifier.height(6.dp))
                Text(
                    text = parentLine,
                    color = SecondaryText,
                    fontSize = 13.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }

            Spacer(Modifier.height(8.dp))

            // Content preview
            Text(
                text = draft.preview.ifEmpty { "(empty draft)" },
                color = PrimaryText,
                fontSize = 15.sp,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
            )

            Spacer(Modifier.height(6.dp))

            // Character count
            Text(
                text = "${draft.content.length} characters",
                color = TertiaryText,
                fontSize = 12.sp,
            )
        }
    }
}
