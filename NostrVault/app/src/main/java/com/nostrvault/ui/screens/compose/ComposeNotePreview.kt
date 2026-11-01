package com.nostrvault.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.NoteTagging
import com.nostrvault.relay.HavenBridge
import com.nostrvault.ui.components.NoteCard
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.SecondaryText

/**
 * The note as it will post, drawn by the feed's own [NoteCard]: links,
 * live-stream cards, quoted notes, hashtags and mentions look exactly as
 * readers will see them. Photos show once their upload has a link.
 */
internal fun ComposeNoteViewModel.previewNote(draft: ComposeNoteDraft): FeedNote {
    var content = convertMentionsToNostr(draft.previewBody())
    val tags = mutableListOf<List<String>>()
    quoteTarget()?.let { quoted ->
        tags += listOf("q", quoted.id, "", quoted.pubkey)
        HavenBridge.hexToNote1(quoted.id)?.let { content += "\nnostr:$it" }
    }
    tags += NoteTagging.hashtagTags(content)
    val media = draft.attachments.mapNotNull { attachment ->
        (draft.upload(attachment.id) as? ComposeNoteUpload.Done)?.media?.takeIf { it.url != null }
            ?.copy(alt = attachment.altText)?.descriptor()
    }
    tags += NoteTagging.imetaTags(media)
    return FeedNote.fromEvent(
        id = PREVIEW_ID,
        pubkey = activeAccount.value?.hexPubkey.orEmpty(),
        content = content,
        tags = tags,
        createdAt = System.currentTimeMillis() / 1000,
        kind = 1,
    )
}

private const val PREVIEW_ID = "compose-preview"

/** The top bar button's word: "Preview" while writing, "Edit" to get back to typing (Logen 2026-11-01). */
internal fun previewButtonLabel(previewing: Boolean): String = if (previewing) "Edit" else "Preview"

/**
 * One button beside Post (iOS: Tory's top bar): Preview shows the note as it
 * will post, and it flips to Edit to go back to typing. On a phone the
 * keyboard owns the bottom half, so the preview swaps in for the editor.
 */
@Composable
internal fun ComposeNotePreviewButton(previewing: Boolean, onToggle: () -> Unit, modifier: Modifier = Modifier) {
    TextButton(
        onClick = onToggle,
        contentPadding = PaddingValues(horizontal = 10.dp),
        modifier = modifier.semantics {
            contentDescription = if (previewing) "Edit, back to typing" else "Preview, the note as it will post"
        },
    ) {
        Text(previewButtonLabel(previewing), color = LocalNostrVaultColors.current.primary, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
    }
}

/** The preview pane, in place of the editor. */
@Composable
internal fun ComposeNotePreview(viewModel: ComposeNoteViewModel, modifier: Modifier = Modifier) {
    val draft by viewModel.draft.collectAsState()
    val profiles by viewModel.nostrService.profiles.collectAsState()
    val quoted by viewModel.feedService.quotedNotes.collectAsState()
    val quotedNote by viewModel.quotedNote.collectAsState()
    val note = viewModel.previewNote(draft)
    Column(modifier.verticalScroll(rememberScrollState())) {
        if (draft.text.isBlank() && draft.attachments.isEmpty()) {
            Text("Nothing to preview yet.", color = SecondaryText, fontSize = 15.sp, modifier = Modifier.padding(16.dp))
            return@Column
        }
        if (draft.unfinished > 0) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
            ) {
                CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp, color = LocalNostrVaultColors.current.primary)
                Text(
                    if (draft.unfinished == 1) "1 photo still uploading, it shows here once it's up"
                    else "${draft.unfinished} photos still uploading, they show here once they're up",
                    color = SecondaryText,
                    fontSize = 13.sp,
                )
            }
        }
        NoteCard(
            note = note,
            profile = profiles[note.pubkey],
            profiles = profiles,
            quotedNotes = quoted + listOfNotNull(quotedNote).associateBy { it.id },
            onNoteClick = {},
            onProfileClick = {},
            modifier = Modifier.fillMaxWidth(),
        )
        Text(
            "This is how your note will look.",
            color = SecondaryText.copy(alpha = 0.7f),
            fontSize = 12.sp,
            modifier = Modifier.padding(16.dp),
        )
    }
}
