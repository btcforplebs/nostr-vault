package com.nostrvault.ui.screens.feed

import androidx.compose.material3.*
import androidx.compose.runtime.*
import com.nostrvault.data.model.FeedMenuSettings
import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.MarketListing
import com.nostrvault.data.model.toNote
import com.nostrvault.ui.components.BroadcastSheet
import com.nostrvault.ui.components.CustomZapSheet
import com.nostrvault.ui.components.EmojiPickerSheet
import com.nostrvault.ui.components.LocalReactionActions
import com.nostrvault.data.local.ReactionPick
import com.nostrvault.ui.components.TrustWebDialog
import com.nostrvault.ui.components.UGCReportDialog
import com.nostrvault.ui.theme.*

/**
 * Which of the feed's sheets and dialogs is open. FeedScreen's rows and toolbar set these
 * (through local delegates, `var zapNoteId by sheets::zapNoteId`); [FeedScreenSheets] shows them.
 */
@Stable
internal class FeedSheetState {
    var zapNoteId by mutableStateOf<String?>(null)
    var showNoLightningAddress by mutableStateOf(false)
    var deleteNoteId by mutableStateOf<String?>(null)
    var reportNoteId by mutableStateOf<String?>(null)
    var blockNoteId by mutableStateOf<String?>(null)
    var emojiPickerNoteId by mutableStateOf<String?>(null)
    var broadcastNoteId by mutableStateOf<String?>(null)
    // The post bar's Web of Trust button: the author whose map is open.
    var trustWebAuthor by mutableStateOf<String?>(null)
    var openListing by mutableStateOf<MarketListing?>(null)
    var listingInfoNote by mutableStateOf<FeedNote?>(null)
    var showFeedMenuEditor by mutableStateOf(false)
    // Global's Everyone scope sits behind a warning (iOS parity).
    var showGlobalEveryoneWarning by mutableStateOf(false)
}

/** The feed's sheets and dialogs: zap, report, block, delete, reactions, event info, trust web, listings, Edit Feeds. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun FeedScreenSheets(
    sheets: FeedSheetState,
    viewModel: FeedViewModel,
    notes: List<FeedNote>,
    allProfiles: Map<String, FeedProfile>,
    feedMode: FeedMode,
    openProfile: (String) -> Unit,
    onProfileClick: (String) -> Unit,
    onMessageUser: (pubkey: String, draft: String) -> Unit,
) {
    var zapNoteId by sheets::zapNoteId
    var showNoLightningAddress by sheets::showNoLightningAddress
    var deleteNoteId by sheets::deleteNoteId
    var reportNoteId by sheets::reportNoteId
    var blockNoteId by sheets::blockNoteId
    var emojiPickerNoteId by sheets::emojiPickerNoteId
    var broadcastNoteId by sheets::broadcastNoteId
    var trustWebAuthor by sheets::trustWebAuthor
    var openListing by sheets::openListing
    var listingInfoNote by sheets::listingInfoNote
    var showFeedMenuEditor by sheets::showFeedMenuEditor
    var showGlobalEveryoneWarning by sheets::showGlobalEveryoneWarning
    val zapSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val emojiSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val broadcastSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    if (showGlobalEveryoneWarning) {
        // Under five follows it says why it's locked instead.
        com.nostrvault.ui.components.EveryoneSwitchDialog(
            onDismiss = { showGlobalEveryoneWarning = false },
            onProceed = {
                viewModel.setGlobalShowsEveryone(true)
                showGlobalEveryoneWarning = false
            },
        )
    }



    if (showNoLightningAddress) {
        AlertDialog(
            onDismissRequest = { showNoLightningAddress = false },
            title = { Text("No Lightning Address") },
            text = { Text("This user hasn't configured a lightning address, so they can't receive zaps.") },
            confirmButton = {
                TextButton(onClick = { showNoLightningAddress = false }) { Text("OK") }
            },
        )
    }

    // Custom zap sheet (long-press on the bolt)
    if (zapNoteId != null) {
        CustomZapSheet(
            sheetState = zapSheetState,
            defaultAmount = viewModel.configStoreRef.config.value.defaultZapAmount,
            onDismiss = { zapNoteId = null },
            onZap = { amount, comment ->
                zapNoteId?.let { viewModel.zapNote(it, amount, comment) }
                zapNoteId = null
            },
        )
    }

    // Report dialog (NIP-56 reason picker). Reporting also blocks the author,
    // matching NoteDetailScreen and iOS.
    val reportTarget = reportNoteId?.let { id -> notes.find { it.id == id || it.effectiveEventId == id } }
    if (reportTarget != null) {
        UGCReportDialog(
            onReport = { reason, description ->
                viewModel.reportNote(
                    reportTarget.effectiveEventId,
                    reportTarget.effectiveAuthor,
                    reason,
                    description,
                )
                reportNoteId = null
            },
            onDismiss = { reportNoteId = null },
        )
    }

    // Block confirmation
    val blockTarget = blockNoteId?.let { id -> notes.find { it.id == id || it.effectiveEventId == id } }
    if (blockTarget != null) {
        AlertDialog(
            onDismissRequest = { blockNoteId = null },
            title = { Text("Block User") },
            text = { Text("Block this user? Their posts will be hidden from your feed.") },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.blockUser(blockTarget.effectiveAuthor)
                        blockNoteId = null
                    },
                ) { Text("Block", color = ErrorRed) }
            },
            dismissButton = {
                TextButton(onClick = { blockNoteId = null }) { Text("Cancel") }
            },
        )
    }

    // Delete confirmation dialog
    if (deleteNoteId != null) {
        AlertDialog(
            onDismissRequest = { deleteNoteId = null },
            title = { Text("Delete Post") },
            text = { Text("Request deletion of this post? Not all relays honor NIP-09 deletion requests.") },
            confirmButton = {
                TextButton(onClick = {
                    deleteNoteId?.let { viewModel.deleteNote(it) }
                    deleteNoteId = null
                }) {
                    Text("Delete", color = ErrorRed)
                }
            },
            dismissButton = {
                TextButton(onClick = { deleteNoteId = null }) {
                    Text("Cancel")
                }
            },
        )
    }

    // Emoji picker sheet
    if (emojiPickerNoteId != null) {
        val reactionActions = LocalReactionActions.current
        EmojiPickerSheet(
            sheetState = emojiSheetState,
            onDismiss = { emojiPickerNoteId = null },
            onSelectEmoji = { emoji ->
                emojiPickerNoteId?.let { viewModel.likeNote(it, emoji) }
                emojiPickerNoteId = null
            },
            onSelectCustom = { custom ->
                emojiPickerNoteId?.let { reactionActions?.pick?.invoke(it, ReactionPick.of(custom)) }
                emojiPickerNoteId = null
            },
        )
    }

    // Broadcast sheet
    val broadcastNote = broadcastNoteId?.let { id -> notes.find { it.id == id || it.effectiveEventId == id } }
    if (broadcastNote != null) {
        BroadcastSheet(
            note = broadcastNote,
            sheetState = broadcastSheetState,
            feedService = viewModel.feedServiceRef,
            nostrService = viewModel.nostrServiceRef,
            configStore = viewModel.configStoreRef,
            onDismiss = { broadcastNoteId = null },
            onProfileClick = { broadcastNoteId = null; openProfile(it) },
        )
    }

    trustWebAuthor?.let { author ->
        TrustWebDialog(
            author = author,
            initialPath = null,
            onProfileClick = openProfile,
            onDismiss = { trustWebAuthor = null },
        )
    }

    openListing?.let { listing ->
        MarketListingSheet(
            listing = listing,
            seller = allProfiles[listing.pubkey],
            onOpenSeller = { pubkey -> openListing = null; onProfileClick(pubkey) },
            onMessageSeller = { openListing = null; onMessageUser(it.pubkey, it.messageToSeller) },
            onEventInfo = { openListing = null; listingInfoNote = it.toNote() },
            onDismiss = { openListing = null },
        )
    }
    // Event Info for a listing: listings are not in `notes`, so the feed's
    // broadcast sheet above cannot find them by id.
    listingInfoNote?.let { note ->
        BroadcastSheet(
            note = note,
            sheetState = broadcastSheetState,
            feedService = viewModel.feedServiceRef,
            nostrService = viewModel.nostrServiceRef,
            configStore = viewModel.configStoreRef,
            onDismiss = { listingInfoNote = null },
            onProfileClick = { listingInfoNote = null; openProfile(it) },
        )
    }

    // Edit Feeds: show, hide and reorder the feed picker's feeds (iOS #303).
    if (showFeedMenuEditor) {
        FeedMenuEditor(
            // Hiding the feed you're on would leave the picker without it.
            onSaved = { hidden -> if (feedMode in hidden) viewModel.setFeedMode(FeedMenuSettings.PINNED) },
            onDismiss = { showFeedMenuEditor = false },
        )
    }
}
