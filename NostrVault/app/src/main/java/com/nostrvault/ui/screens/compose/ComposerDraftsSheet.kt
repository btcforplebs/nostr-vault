package com.nostrvault.ui.screens

import android.graphics.BitmapFactory
import android.text.format.DateUtils
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.TertiaryText
import com.nostrvault.ui.theme.WindowBackground

/**
 * Saves [current] a short pause after each change, and once more when the
 * screen leaves (back, a switch of account, or the app closing it), so
 * leaving any way but Discard keeps the work. Twin of the iOS composers'
 * `.onChange` and `.onDisappear` saves.
 */
@Composable
internal fun AutosaveComposerDraft(keeper: ComposerDraftKeeper, current: ComposerDraft, cover: java.io.File?) {
    LaunchedEffect(current, cover) { keeper.changed(current, cover) }
    val latest by rememberUpdatedState(current to cover)
    DisposableEffect(keeper) {
        onDispose { keeper.saveNow(latest.first, latest.second) }
    }
}

/**
 * The row at the top of an article, recipe or poll composer that opens its
 * saved drafts. Shown only when there are some, so a first-time composer
 * stays uncluttered. Twin of iOS `ComposerDraftsRow`.
 */
@Composable
internal fun ComposerDraftsRow(keeper: ComposerDraftKeeper, onClick: () -> Unit) {
    val others by keeper.others.collectAsState()
    if (others.isEmpty()) return
    val colors = LocalNostrVaultColors.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(colors.primary.copy(alpha = 0.10f))
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 12.dp),
    ) {
        Icon(NostrVaultIcons.Activity, contentDescription = null, tint = colors.primary, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(10.dp))
        Text(
            if (others.size == 1) "1 saved draft" else "${others.size} saved drafts",
            color = colors.primary,
            fontWeight = FontWeight.Medium,
            modifier = Modifier.weight(1f),
        )
        Icon(NostrVaultIcons.Navigate, contentDescription = null, tint = SecondaryText, modifier = Modifier.size(18.dp))
    }
}

/**
 * The saved drafts of one kind. Tapping one loads it into the composer; the
 * trash button deletes it after a yes. Twin of iOS `ComposerDraftsSheet`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ComposerDraftsSheet(
    keeper: ComposerDraftKeeper,
    store: ComposerDraftStore,
    onSelect: (ComposerDraft) -> Unit,
    onDismiss: () -> Unit,
) {
    val others by keeper.others.collectAsState()
    var pendingDelete by remember { mutableStateOf<ComposerDraft?>(null) }
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, containerColor = WindowBackground) {
        Text(
            keeper.kind.listTitle,
            color = PrimaryText,
            fontSize = 17.sp,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp),
        )
        if (others.isEmpty()) {
            Text(
                "No drafts",
                color = SecondaryText,
                modifier = Modifier.padding(20.dp).fillMaxWidth(),
            )
        } else {
            LazyColumn(
                modifier = Modifier.navigationBarsPadding(),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                items(others, key = { it.id }) { draft ->
                    DraftRow(
                        draft = draft,
                        cover = store.cover(draft, keeper.account),
                        onOpen = { onSelect(draft); onDismiss() },
                        onDelete = { pendingDelete = draft },
                    )
                }
            }
        }
        Spacer(Modifier.height(16.dp))
    }

    pendingDelete?.let { draft ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("Delete this draft?", fontWeight = FontWeight.Bold) },
            text = { Text("It's only on this device, so it can't be recovered.") },
            confirmButton = {
                TextButton(onClick = {
                    keeper.delete(draft)
                    pendingDelete = null
                }) { Text("Delete", color = ErrorRed, fontWeight = FontWeight.Bold) }
            },
            dismissButton = {
                TextButton(onClick = { pendingDelete = null }) { Text("Cancel") }
            },
            containerColor = WindowBackground,
        )
    }
}

@Composable
private fun DraftRow(draft: ComposerDraft, cover: java.io.File?, onOpen: () -> Unit, onDelete: () -> Unit) {
    val colors = LocalNostrVaultColors.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClickLabel = "Open this draft", onClick = onOpen)
            .padding(start = 20.dp, end = 8.dp, top = 8.dp, bottom = 8.dp),
    ) {
        val thumb = remember(cover?.path, cover?.lastModified()) {
            cover?.let { file ->
                runCatching {
                    BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = 8 })
                }.getOrNull()
            }
        }
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .size(48.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(colors.primary.copy(alpha = 0.15f)),
        ) {
            if (thumb != null) {
                Image(thumb.asImageBitmap(), contentDescription = null, contentScale = ContentScale.Crop,
                    modifier = Modifier.size(48.dp))
            } else {
                Icon(
                    when (draft.kind) {
                        ComposerDraft.Kind.ARTICLE -> NostrVaultIcons.Articles
                        ComposerDraft.Kind.RECIPE -> NostrVaultIcons.Recipes
                        ComposerDraft.Kind.POLL -> NostrVaultIcons.Polls
                    },
                    contentDescription = null,
                    tint = colors.primary,
                )
            }
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(draft.previewTitle, color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold,
                maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (draft.previewDetail.isNotEmpty()) {
                Text(draft.previewDetail, color = SecondaryText, fontSize = 13.sp, maxLines = 2,
                    overflow = TextOverflow.Ellipsis)
            }
            Text(
                DateUtils.getRelativeTimeSpanString(draft.updatedAt, System.currentTimeMillis(),
                    DateUtils.MINUTE_IN_MILLIS).toString(),
                color = TertiaryText,
                fontSize = 11.sp,
            )
        }
        IconButton(onClick = onDelete, modifier = Modifier.semantics { contentDescription = "Delete draft" }) {
            Icon(NostrVaultIcons.Delete, contentDescription = null, tint = SecondaryText)
        }
    }
}

/**
 * "Save this article as a draft?" on Cancel or back, once there is something
 * to keep. [editsSavedDraft] turns Discard into Discard Changes, which puts a
 * draft picked from the list back as it was. Twin of the iOS composers'
 * confirmation dialog.
 */
@Composable
internal fun SaveComposerDraftPrompt(
    noun: String,
    editsSavedDraft: Boolean,
    onSave: () -> Unit,
    onDiscard: () -> Unit,
    onKeepEditing: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onKeepEditing,
        title = { Text("Save this $noun as a draft?") },
        text = { Text("Saved drafts stay on this device. Find them at the top of this editor.") },
        confirmButton = {
            TextButton(onClick = onSave) { Text("Save Draft") }
        },
        dismissButton = {
            Row {
                TextButton(onClick = onDiscard) {
                    Text(if (editsSavedDraft) "Discard Changes" else "Discard", color = ErrorRed)
                }
                TextButton(onClick = onKeepEditing) { Text("Keep Editing") }
            }
        },
        containerColor = WindowBackground,
    )
}
