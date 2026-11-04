package com.nostrvault.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.service.NostrEvent
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.components.formatTimestamp
import com.nostrvault.ui.theme.NostrVaultIcons

/**
 * The Vault media viewer's swipe up: every note on the vault that uses the
 * file (MediaNoteMatch), newest first, in a half sheet. A row opens the note.
 * iOS: MediaNotesSheet.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun MediaNotesSheet(
    notes: List<NostrEvent>,
    profiles: Map<String, FeedProfile>,
    onOpen: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = Color(0xFF151518)) {
        Text(
            if (notes.size == 1) "1 note" else "${notes.size} notes",
            color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 16.sp,
            modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp),
        )
        if (notes.isEmpty()) {
            Text(
                "No note on your vault uses this file",
                color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp,
                modifier = Modifier.fillMaxWidth().padding(32.dp),
            )
        } else {
            LazyColumn(modifier = Modifier.fillMaxWidth().heightIn(max = 480.dp)) {
                items(notes, key = { it.id }) { note -> NoteRow(note, profiles[note.pubkey]) { onOpen(note.id) } }
            }
        }
        Spacer(Modifier.navigationBarsPadding().height(12.dp))
    }
}

@Composable
private fun NoteRow(note: NostrEvent, profile: FeedProfile?, onClick: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 20.dp, vertical = 10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        AvatarImage(url = profile?.pictureURL, pubkey = note.pubkey, size = 36.dp, displayName = profile?.bestName)
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(profile?.bestName ?: note.pubkey.take(10), color = Color.White, fontWeight = FontWeight.SemiBold,
                    fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                Spacer(Modifier.width(6.dp))
                Text(formatTimestamp(note.createdAt), color = Color.White.copy(alpha = 0.5f), fontSize = 12.sp, maxLines = 1)
            }
            Text(notePreview(note.content), color = Color.White.copy(alpha = 0.7f), fontSize = 14.sp,
                maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** The text with its links folded away, so two lines say something. */
internal fun notePreview(content: String): String =
    content.split(Regex("\\s+")).filter { it.isNotEmpty() && !it.startsWith("http") }.joinToString(" ").ifEmpty { "(media only)" }

/** The grabber at the foot of a media viewer: swipe up, or tap it, for the note(s). */
@Composable
internal fun MediaNoteGrabber(title: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Row(
        modifier = modifier
            .background(Color.White.copy(alpha = 0.14f), RoundedCornerShape(50))
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(NostrVaultIcons.ChevronUp, contentDescription = null, tint = Color.White.copy(alpha = 0.85f), modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(6.dp))
        Text(title, color = Color.White.copy(alpha = 0.85f), fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
    }
}
